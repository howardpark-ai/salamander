#!/usr/bin/env bash
# The plugin reload (lib/plugin-reload.sh, `sala watch --plugins`): after an update of a watched plugin, the pane of a BACKGROUND AGENT is asked
# through its sala mod to run /reload-plugins. Against fake claude panes on a private tmux server and a fake mod (one unix socket per pane that
# takes session_push's line and writes the reply and the <sessionId>.reload.json the way the mod does). Checks:
#   OFF by default: a pass asks nobody and writes nothing; --dry-run says who would be asked, that every other pane is left alone, and writes nothing.
#   WHO: only a registry row with role back and no side session. A front agent, a side session and a pane with no mod are not asked; a background
#   agent that is the Remote Control session, a served session, on the sdk lane, asleep, in SALA_NO_RELAUNCH, paused, waiting for a relaunch
#   (flag under either conversation id, deferred list, open relaunch set, queued, running or waiting operation) is skipped, and the reason said;
#   a closed set and a done operation hold nobody. The whole pass stands aside on another tmux server and while the pane map is frozen.
#   STALE: an update of a watched plugin later than the claude's start and its last confirmed reload, read from the pane's own config directory;
#   one confirmed reload per version (the same version recorded again asks nobody, also for a pane that started with it); another plugin's update
#   does not count; no plugin named: nobody is asked, said once.
#   ANSWERS: ok makes the pane current until the next update; no answer is asked again after SALA_PLUGIN_RELOAD_RETRY; at most
#   SALA_PLUGIN_RELOAD_TRIES requests per version with no confirmed reload, whatever came of them; a mod without the verb is asked once, said
#   once; the per-pass cap.
#   IDLE WRAP-UP: after a request, the moved registry stamp does not change what `watch --wrapup` decides, until a turn ends.
#   --only: asks one background agent now, on or off and stale or not, under the same exclusions; exit 0 ran, 1 not asked or no reload, 4 no answer yet;
#   a wrong argument is refused (2).
#   The watch's own pass runs it only with SALA_PLUGIN_RELOAD=on, and the settings are read from the config file.
# Nothing is typed into a pane. Isolated HOME in a temp folder (locked while the suite runs, removed at the end), a private tmux server started with
# -f /dev/null, the compiled fake claude. Usage: bash tests/plugin-reload.sh   (exit 0 = pass; two to three minutes)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_SET SALA_RECYCLE SALA_RETRY_WORKER SALA_NO_RELAUNCH CLAUDE_CODE_PLUGIN_DIRS SALA_MOD_DIR \
      SALA_PLUGIN_RELOAD SALA_PLUGIN_RELOAD_IDS SALA_PLUGIN_RELOAD_MAX SALA_PLUGIN_RELOAD_RETRY SALA_PLUGIN_RELOAD_TRIES SALA_PLUGIN_RELOAD_WAIT \
      SALA_IDLE_WRAPUP SALA_IDLE_WRAPUP_MIN SALA_IDLE_WRAPUP_MAX_AGE SALA_IDLE_SETTLE SALA_RC_SESSION
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
TD=""; SOCK="sala-plugins-$$"; FAKEMOD=""; FAKEBIN=""
cleanup() {
    [ -n "$TD" ] || return 0
    : > "$TD/stop"                                             # the fake mod leaves by itself
    command tmux -L "$SOCK" -f /dev/null kill-server 2>/dev/null; tmux_socket_rm "$SOCK"
    [ -z "$FAKEMOD" ] || wait "$FAKEMOD" 2>/dev/null
    local d; for d in /proc/[0-9]*; do [ -n "$FAKEBIN" ] && [ "$d/exe" -ef "$FAKEBIN" ] && kill -9 "${d#/proc/}" 2>/dev/null; done
    rm -rf "$TD" 2>/dev/null; true
}
TD=$(mktemp -d "${TMPDIR:-/tmp}/sala-plugins.XXXXXX") || exit 1; trap cleanup EXIT
exec {HOLD}< "$TD"; flock -n "$HOLD" 2>/dev/null           # systemd-tmpfiles' ageing skips a directory held with flock
export HOME="$TD/home" SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC XDG_RUNTIME_DIR="$TD/run"
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.claude/plugins" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect" "$XDG_RUNTIME_DIR" "$TD/cfg/plugins"
touch "$HOME/.claude/salamander-rc.stopped"                # no Remote Control server in the sandbox
mkdir -p "$HOME/.local/share/claude/versions"; FAKEBIN="$HOME/.local/share/claude/versions/9.9.9"
cc -o "$FAKEBIN" "$ROOT/tests/fake-claude.c" || exit 1
ln -s "$FAKEBIN" "$HOME/.local/bin/claude"
export PATH="$HOME/.local/bin:$PATH" SALA_NOTIFY_CMD="cat >> $TD/posts" FAKE_TYPED_LOG="$TD/typed.log"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off SALA_MOD_WAIT=1
SALA="$ROOT/bin/salamander"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # this server stands in for the fleet's (common.sh, on_fleet_server)
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux
. "$ROOT/lib/common.sh"
RUN="$XDG_RUNTIME_DIR/sala/mod"; HEARD="$TD/heard"; : > "$HEARD"
WLOG="$SALA_LOG_DIR/salamander-watch.log"; STATE="$SALA_STATE_DIR/plugin-reload.tsv"
mkdir -p "$RUN" "$SALA_STATE_DIR" "$SALA_LOG_DIR"

# THE PANES: name, role, side, and what else its tmux session carries
NAMES="back two front side nomod old sdk cfg served"
uuid() { local i=0 n; for n in $NAMES; do i=$((i + 1)); [ "$n" = "$1" ] && break; done; printf '%08d-0000-4000-8000-%012d' "$i" "$i"; }
pane_up() {  # <short name> [tmux -e NAME=value …]; CARGS: arguments for its claude
    local n=$1 s="sala-test-$1"; shift
    tmux new-session -d -s "$s" -x 100 -y 30 -e "FAKE_SESSION_ID=$(uuid "$n")" -e "FAKE_NAME=$s" "$@" "bash --norc --noprofile -c 'claude ${CARGS:-}; sleep 600'"
}
tmux new-session -d -s keep-alive
for n in back two front side nomod old; do pane_up "$n"; done
pane_up sdk -e CLAUDE_CODE_ENTRYPOINT=sdk-py
pane_up cfg -e "CLAUDE_CONFIG_DIR=$TD/cfg"
CARGS="--sdk-url ws://127.0.0.1:9/none" pane_up served   # what a Remote Control served session carries
for n in $NAMES; do fake_up "sala-test-$n" || { echo "the fake panes did not start"; exit 1; }; done
pid_of() { local f c; for f in "$HOME"/.claude/sessions/*.json; do c=$(<"$f"); case "$c" in *"$(uuid "$1")"*) f=${f##*/}; echo "${f%.json}"; return 0;; esac; done; return 1; }

# the sala session registry: who is a background agent
python3 -I -S - "$SALA_SESSIONS_FILE" <<'PY'
import json, os, sys
rows = {}
for n, role, side in (("back", "back", None), ("two", "back", None), ("front", "front", None), ("side", "back", "fork"),
                      ("nomod", "back", None), ("old", "back", None), ("sdk", "back", None), ("cfg", "back", None), ("served", "back", None)):
    s = "sala-test-" + n
    rows[s] = {"id": s, "name": s, "state": "live", "role": role, "side": side, "project": "projects/x", "created": s}
os.makedirs(os.path.dirname(sys.argv[1]), exist_ok=True)
json.dump({"schema": 1, "sessions": rows}, open(sys.argv[1], "w"))
PY

# THE FAKE MOD: one socket per pane (every pane but nomod has one, with its presence stamp). The mode file $TD/mode.<name>:
#   ok (default) the reload ran · refused another answer · later accepted, nothing written · slow written after the reply · old no such verb
cat > "$TD/fakemod.py" <<'PY'
import json, os, socket, sys, threading, time
base, run, names = sys.argv[1], sys.argv[2], sys.argv[3:]
def rd(p, d=""):
    try: return open(p).read().strip()
    except Exception: return d
def put(path, obj):
    open(path + ".tmp", "w").write(json.dumps(obj) + "\n"); os.replace(path + ".tmp", path)
def serve(c, name, sid):
    data = b""
    while not data.endswith(b"\n"):
        b = c.recv(65536)
        if not b: break
        data += b
    c.close()
    try: text = json.loads(data)["message"]["content"]
    except Exception: return
    if not text.startswith("[sala-mod] "): return
    verb, req = text[len("[sala-mod] "):].split("\n")[0].split(" ")[:2]
    open(os.path.join(base, "heard"), "a").write("%s %s\n" % (name, verb))
    mode = rd(os.path.join(base, "mode." + name), "ok")
    reply = os.path.join(run, "%s.%s.reply.json" % (sid, req))
    if verb != "reload" or mode == "old":
        put(reply, {"reqid": req, "ok": False, "reason": "unknown"}); return
    begun = int(time.time() * 1000)
    ran = {"begun": begun, "ok": True, "text": "Reloaded: 2 plugins"}
    if mode == "refused": ran = {"begun": begun, "ok": False, "text": "Plugins changed. Run /reload-plugins --force to apply."}
    state = os.path.join(run, sid + ".reload.json")
    if mode in ("ok", "refused"): put(state, ran)
    put(reply, {"reqid": req, "ok": True})
    if mode == "slow":
        time.sleep(0.6); put(state, ran)
def listen(s, name, sid):
    while True:
        try: c, _ = s.accept()
        except socket.timeout: continue
        c.settimeout(5); threading.Thread(target=serve, args=(c, name, sid), daemon=True).start()
for pair in names:
    name, sid, path = pair.split("=")
    s = socket.socket(socket.AF_UNIX); s.bind(path); s.listen(8); s.settimeout(0.5)
    threading.Thread(target=listen, args=(s, name, sid), daemon=True).start()
open(os.path.join(base, "mod.up"), "w").close()
end = time.time() + 3600   # a safety net only, well past a traced run on a loaded box
while time.time() < end and os.path.isdir(base) and not os.path.exists(os.path.join(base, "stop")): time.sleep(0.2)
PY
PAIRS=(); i=0
for n in $NAMES; do
    i=$((i + 1)); [ "$n" = nomod ] && continue
    PAIRS+=("$n=$(uuid "$n")=$TD/m$i.sock")
    python3 -I -c 'import json,sys; f=sys.argv[1]; d=json.load(open(f)); d["messagingSocketPath"]=sys.argv[2]; json.dump(d,open(f,"w"))' "$HOME/.claude/sessions/$(pid_of "$n").json" "$TD/m$i.sock"
done
python3 -I "$TD/fakemod.py" "$TD" "$RUN" "${PAIRS[@]}" & FAKEMOD=$!
waitfor '[ -e "$TD/mod.up" ]' 20 || { echo "the fake mod did not start"; exit 1; }
for n in $NAMES; do [ "$n" = nomod ] || printf '{"present":true,"version":1,"sessionId":"%s","at":%s000}\n' "$(uuid "$n")" "$(date +%s)" > "$RUN/$(uuid "$n").json"; done
nap 3.2   # an update must be later than a claude's start, which sala knows to the second

# deploy [<plugin id> [<config dir> [<offset s> [<version>]]]] — the install record there says that plugin was updated now (plus the offset)
deploy() {
    python3 -I -S - "${2:-$HOME/.claude}/plugins/installed_plugins.json" "${1:-demo@demo-market}" "${3:--1}" "${4:-1.2.0}" <<'PY'
import datetime, json, os, sys
path, name, off = sys.argv[1], sys.argv[2], float(sys.argv[3])
try: d = json.load(open(path))
except Exception: d = {"version": 2, "plugins": {}}
t = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=off)
d["plugins"][name] = [{"scope": "user", "version": sys.argv[4], "lastUpdated": t.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (t.microsecond // 1000)}]
json.dump(d, open(path, "w"))
PY
}
reset() {  # no state, no answers, nothing heard, every fake mod mode ok, and the watched plugin just updated in the default config directory
    rm -f "$STATE" "$RUN"/*.reload.json "$TD"/mode.* "$HOME/.claude/plugins/installed_plugins.json" "$TD/cfg/plugins/installed_plugins.json"
    : > "$HEARD"; : > "$WLOG"; deploy
}
export SALA_PLUGIN_RELOAD_IDS="demo@demo-market"
pass() { SALA_PLUGIN_RELOAD=on "$SALA" watch --plugins 2>&1; }
dry() { "$SALA" watch --plugins --dry-run "$@" 2>&1; }
only() { SALA_PLUGIN_RELOAD_WAIT=${WAIT:-5} "$SALA" watch --plugins --only "sala-test-$1" 2>&1; }
asks() { local n; n=$(grep -c "^$1 reload\$" "$HEARD" 2>/dev/null); echo "${n:-0}"; }
heard() { sort -u "$HEARD" | awk '{print $1}' | paste -sd' '; }
logged() { local n; n=$(grep -cF -- "$1" "$WLOG" 2>/dev/null); echo "${n:-0}"; }
has() { case "$1" in *"$2"*) return 0;; esac; return 1; }

echo "== off by default"
reset
out=$("$SALA" watch --plugins 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" "SALA_PLUGIN_RELOAD is not on" && ok "watch --plugins says the reload is off" || bad "off: rc=$rc $out"
[ ! -s "$HEARD" ] && [ ! -e "$STATE" ] && [ "$(logged plugins:)" = 0 ] && ok "off: nobody asked, no state, no log line" || bad "off wrote: heard $(heard); log $(grep plugins: "$WLOG")"

echo "== --dry-run: who would be asked, and nothing written"
out=$(dry); rc=$?
[ "$rc" = 0 ] && has "$out" "only panes of background agents are asked to reload; every other pane is left alone and loads the new version at its next start" && ok "it says who is asked and what the others do" || bad "dry head: rc=$rc $out"
has "$out" "SALA_PLUGIN_RELOAD is off" && ok "it says the setting is off" || bad "dry off: $out"
has "$out" "sala-test-back: would be asked to reload (demo@demo-market 1.2.0" && ok "a stale background agent would be asked" || bad "dry back: $out"
has "$out" "sala-test-front: left alone, not a background agent: it loads the new version at its next start" && ok "a front agent is left alone, said" || bad "dry front: $out"
has "$out" "sala-test-side: left alone, not a background agent" && ok "a side session is left alone" || bad "dry side: $out"
has "$out" "sala-test-nomod: no sala mod to ask" && ok "a pane with no mod: said" || bad "dry nomod: $out"
has "$out" "sala-test-sdk: skipped: on the sdk lane" && ok "an sdk-lane pane is skipped" || bad "dry sdk: $out"
has "$out" "sala-test-served: skipped: a Remote Control served session" && ok "a Remote Control served session is skipped" || bad "dry served: $out"
has "$out" "sala-test-cfg: no watched plugin in $TD/cfg/plugins/installed_plugins.json" && ok "a pane's own config directory is read" || bad "dry cfg: $out"
[ ! -s "$HEARD" ] && [ ! -e "$STATE" ] && [ "$(logged plugins:)" = 0 ] && ok "a dry run asks nobody and writes nothing" || bad "dry wrote: heard $(heard); $(cat "$WLOG")"

echo "== no plugin named"
out=$(SALA_PLUGIN_RELOAD_IDS="" dry); has "$out" "SALA_PLUGIN_RELOAD_IDS names no plugin" && ! has "$out" "would be asked" && ok "dry run: said, nobody would be asked" || bad "no ids dry: $out"
SALA_PLUGIN_RELOAD_IDS="" pass >/dev/null; SALA_PLUGIN_RELOAD_IDS="" pass >/dev/null
[ ! -s "$HEARD" ] && [ "$(logged 'names no plugin')" = 1 ] && ok "on with no plugin named: nobody asked, one log line over two passes" || bad "no ids: heard $(heard) lines $(logged 'names no plugin')"

echo "== the per-pass cap, then a real pass"
reset
SALA_PLUGIN_RELOAD_MAX=1 pass >/dev/null
[ "$(grep -c . "$HEARD")" = 1 ] && [ "$(logged 'panes are asked per pass')" -ge 1 ] && ok "SALA_PLUGIN_RELOAD_MAX=1: one pane asked, the rest wait" || bad "cap: heard $(cat "$HEARD"); $(cat "$WLOG")"
reset; out=$(pass); rc=$?
[ "$rc" = 0 ] && [ "$(heard)" = "back old two" ] && ok "on: exactly the background agents with a mod are asked" || bad "pass: rc=$rc heard '$(heard)' $out; $(cat "$WLOG")"
[ "$(logged 'plugins: sala-test-back: asked to reload (demo@demo-market 1.2.0')" = 1 ] && ok "the request is logged with the plugin and its version" || bad "log: $(cat "$WLOG")"
[ "$(logged 'plugins: sala-test-front')" = 0 ] && [ "$(logged 'plugins: sala-test-side')" = 0 ] && ok "no log line for a pane that is not a background agent" || bad "front logged: $(cat "$WLOG")"
[ ! -s "$FAKE_TYPED_LOG" ] && ok "nothing is typed into a pane" || bad "typed: $(cat "$FAKE_TYPED_LOG")"

echo "== the answer: current until the next update"
pass >/dev/null
[ "$(logged 'plugins: sala-test-back: the reload ran: Reloaded: 2 plugins')" = 1 ] && [ ! -e "$RUN/$(uuid back).reload.json" ] && ok "the mod's answer is read, logged and removed" || bad "collect: $(cat "$WLOG"); $(ls "$RUN")"
[ "$(asks back)" = 1 ] && ok "a confirmed pane is not asked again" || bad "asked $(asks back)"
out=$(dry); has "$out" "sala-test-back: current" && ok "a dry run calls it current" || bad "dry current: $out"
deploy other@demo-market "$HOME/.claude" 0; pass >/dev/null
[ "$(asks back)" = 1 ] && ok "another plugin's update does not make it stale" || bad "other plugin: asked $(asks back)"
nap 0.3; deploy demo@demo-market "$HOME/.claude" 0; pass >/dev/null; out=$(dry)
[ "$(asks back)" = 1 ] && has "$out" "sala-test-back: current" && ok "the same version recorded again: not asked, once per version" || bad "same version: asked $(asks back); $out"
nap 0.3; deploy demo@demo-market "$HOME/.claude" 0 1.3.0; pass >/dev/null
[ "$(asks back)" = 2 ] && ok "the next version of the watched plugin: asked again" || bad "next version: asked $(asks back); $(cat "$WLOG")"
: > "$HEARD"; deploy demo@demo-market "$TD/cfg" -1; pass >/dev/null
[ "$(asks cfg)" = 1 ] && ok "an update in a pane's own config directory asks that pane" || bad "cfg: heard $(heard)"

echo "== a version that was there when the claude started"
reset; deploy demo@demo-market "$HOME/.claude" -3600; pass >/dev/null; out=$(dry)
[ "$(asks back)" = 0 ] && has "$out" "sala-test-back: current" && ok "installed before the pane's claude started: not asked" || bad "before start: asked $(asks back); $out"
nap 0.3; deploy demo@demo-market "$HOME/.claude" 0; pass >/dev/null
[ "$(asks back)" = 0 ] && ok "recorded again with the same version: still not asked" || bad "rewritten: asked $(asks back); $(cat "$WLOG")"
nap 0.3; deploy demo@demo-market "$HOME/.claude" 0 1.3.0; pass >/dev/null
[ "$(asks back)" = 1 ] && ok "a newer version after it: asked" || bad "after start version: asked $(asks back); $(cat "$WLOG")"

echo "== an answer that is no reload: counted, then given up on"
reset; echo refused > "$TD/mode.back"
for _ in 1 2 3 4 5; do SALA_PLUGIN_RELOAD_RETRY=0 pass >/dev/null; done
[ "$(asks back)" = 3 ] && ok "three answers that are no reload: three requests, no fourth" || bad "tries: asked $(asks back); $(cat "$WLOG")"
[ "$(logged 'sala-test-back: the reload did not run (request 3 of 3 for this version): Plugins changed')" = 1 ] && [ "$(logged 'sala-test-back: demo@demo-market 1.2.0: not asked again after 3 requests')" = 1 ] && ok "logged, with the words and the give-up" || bad "refusal log: $(cat "$WLOG")"
out=$(SALA_PLUGIN_RELOAD_RETRY=0 dry); has "$out" "sala-test-back: demo@demo-market 1.2.0: not asked again after 3" && ok "a dry run says why" || bad "gave up dry: $out"
grep -q -- '--force' "$HEARD" && bad "--force went out" || ok "no request carries --force"
nap 0.3; deploy demo@demo-market "$HOME/.claude" 0; SALA_PLUGIN_RELOAD_RETRY=0 pass >/dev/null
[ "$(asks back)" = 3 ] && ok "the same version recorded again stays given up on" || bad "same version after give-up: asked $(asks back)"
nap 0.3; deploy demo@demo-market "$HOME/.claude" 0 1.3.0; SALA_PLUGIN_RELOAD_RETRY=0 pass >/dev/null
[ "$(asks back)" = 4 ] && ok "a newer version is asked for again" || bad "after update: asked $(asks back)"
reset; echo refused > "$TD/mode.back"; pass >/dev/null; pass >/dev/null
[ "$(asks back)" = 1 ] && ok "a refusal is not asked again before SALA_PLUGIN_RELOAD_RETRY" || bad "refusal spacing: asked $(asks back)"

echo "== no answer: asked again after SALA_PLUGIN_RELOAD_RETRY"
reset; echo later > "$TD/mode.back"; pass >/dev/null; pass >/dev/null
[ "$(asks back)" = 1 ] && ok "not confirmed: not asked again at once" || bad "later: asked $(asks back)"
out=$(dry); has "$out" "sala-test-back: asked 0 min ago, no reload confirmed: asked again after 30 min" && ok "a dry run says when it will be" || bad "later dry: $out"
awk -F'\t' -v OFS='\t' '{ $2 = $2 - 1801; print }' "$STATE" > "$STATE.t" && mv "$STATE.t" "$STATE"; pass >/dev/null
[ "$(asks back)" = 2 ] && [ "$(logged 'again, 30 min after the last request')" -ge 1 ] && ok "after 30 minutes: asked again" || bad "retry: asked $(asks back); $(cat "$WLOG")"
for _ in 1 2 3 4; do SALA_PLUGIN_RELOAD_RETRY=0 pass >/dev/null; done
[ "$(asks back)" = 3 ] && [ "$(logged 'sala-test-back: demo@demo-market 1.2.0: not asked again after 3 requests')" = 1 ] && ok "never answered: three requests per version, no fourth, said once" || bad "unanswered bound: asked $(asks back); $(cat "$WLOG")"

echo "== a mod without the verb"
reset; echo old > "$TD/mode.old"; for _ in 1 2 3; do SALA_PLUGIN_RELOAD_RETRY=0 pass >/dev/null; done
[ "$(asks old)" = 1 ] && [ "$(logged 'sala-test-old: its sala mod does not know reload')" = 1 ] && ok "answered unknown: asked once, said once" || bad "old: asked $(asks old); $(cat "$WLOG")"
nap 0.3; deploy demo@demo-market "$HOME/.claude" 0 1.3.0; SALA_PLUGIN_RELOAD_RETRY=0 pass >/dev/null; out=$(dry)
[ "$(asks old)" = 1 ] && has "$out" "sala-test-old: its sala mod does not know reload" && ok "a newer version does not ask that claude again" || bad "old after update: asked $(asks old); $out"

echo "== a background agent that is exiting, being relaunched or asleep is skipped"
U=$(uuid back); P=$(pid_of back)
skip_case() {  # <label> <reason words> — the marker is in place: a pass leaves the pane, the dry run says why
    local out; : > "$HEARD"; rm -f "$STATE" "$RUN"/*.reload.json
    pass >/dev/null; out=$(dry)
    [ "$(asks back)" = 0 ] && [ "$(asks two)" = 1 ] && has "$out" "sala-test-back: skipped: $2" && ok "$1: skipped" || bad "$1: asked $(asks back)/$(asks two); $out"
}
reset
mkdir -p "$SALA_PAUSE_DIR"; printf 'pid=%s\nat=%s\n' "$P" "$(date +%s)" > "$SALA_PAUSE_DIR/$U.paused"; skip_case "paused" "paused for a relaunch"; rm -f "$SALA_PAUSE_DIR/$U.paused"
mkdir -p "$SALA_WAITING_DIR"; : > "$SALA_WAITING_DIR/$U"; skip_case "a waiting flag" "a relaunch waits for it (waiting flag)"; rm -f "$SALA_WAITING_DIR/$U"
printf 'sala-test-back\t%s\tscheduled work\n' "$U" > "$SALA_DEFERRED"; skip_case "the deferred list" "a relaunch waits for it (deferred list)"; rm -f "$SALA_DEFERRED"
mkdir -p "$SALA_STATE_DIR/ops"; printf 'verb=recycle\nstate=queued\narg=sala-test-back\n' > "$SALA_STATE_DIR/ops/1760000000-1.op"; skip_case "a queued operation" "operation 1760000000-1 (queued) names it"; rm -f "$SALA_STATE_DIR/ops/1760000000-1.op"
printf 'sala-test-back\t%s\tsala-test-back\n' "$U" > "$SALA_SIDECAR"; sleeping_mark "$U" sala-test-back; skip_case "asleep" "asleep"
out=$(only back); rc=$?; [ "$rc" = 1 ] && [ "$(asks back)" = 0 ] && has "$out" "asleep" && ok "--only honors it" || bad "only asleep: rc=$rc $out"
rm -f "$SALA_SLEEP_DIR/$U" "$SALA_SIDECAR"
out=$(SALA_NO_RELAUNCH=sala-test-back dry); has "$out" "sala-test-back: skipped: managed outside sala" && ok "SALA_NO_RELAUNCH: skipped" || bad "no relaunch: $out"
export SALA_RC_SESSION=sala-test-back; skip_case "the Remote Control session" "the Remote Control session"; unset SALA_RC_SESSION
U2=99999999-0000-4000-8000-000000000099   # the conversation the pane map holds, not the one the registry row is in
printf 'sala-test-back\t%s\tsala-test-back\n' "$U2" > "$SALA_SIDECAR"; : > "$SALA_WAITING_DIR/$U2"; skip_case "a waiting flag under the pane map's id" "a relaunch waits for it (waiting flag)"; rm -f "$SALA_WAITING_DIR/$U2" "$SALA_SIDECAR"
mkdir -p "$SALA_SET_DIR"; SET="$SALA_SET_DIR/1760000000-2"
printf 'scope=test\nout=sala-test-back\n' > "$SET"; skip_case "an open relaunch set" "an open relaunch set (1760000000-2) waits for it"
for st in running waiting; do
    rm -f "$SET"; printf 'verb=recycle\nstate=%s\narg=sala-test-back\n' "$st" > "$SALA_STATE_DIR/ops/1760000000-3.op"; skip_case "a $st operation" "operation 1760000000-3 ($st) names it"
done
printf 'verb=recycle\nstate=done\narg=sala-test-back\n' > "$SALA_STATE_DIR/ops/1760000000-3.op"; printf 'scope=test\nout=sala-test-back\nclosed=1\n' > "$SET"
: > "$HEARD"; rm -f "$STATE" "$RUN"/*.reload.json; pass >/dev/null
[ "$(asks back)" = 1 ] && ok "a closed set and a done operation hold nobody" || bad "closed: asked $(asks back); $(cat "$WLOG")"
rm -f "$SET" "$SALA_STATE_DIR/ops/1760000000-3.op"

echo "== the whole pass stands aside"
reset; out=$(SALA_TMUX_SOCKET="$TD/other.sock" pass; SALA_TMUX_SOCKET="$TD/other.sock" dry)
[ ! -s "$HEARD" ] && has "$out" "not the fleet's tmux server: nothing is asked" && ok "another tmux server: nobody asked" || bad "other server: heard $(heard); $out"
reset; printf 'reason=test\nowner_pid=%s\ntime=%s\n' "$$" "$(date +%s)" > "$SALA_LEDGER_FREEZE"
pass >/dev/null; out=$(dry)
[ ! -s "$HEARD" ] && has "$out" "standing aside: the pane map is frozen" && ok "the pane map frozen: nobody asked" || bad "frozen: heard $(heard); $out"
rm -f "$SALA_LEDGER_FREEZE"

echo "== idle wrap-up: a requested reload starts no new idle stretch"
P=$(pid_of back)
row() {  # <key=epoch seconds …> — those fields of back's registry row, in ms
    python3 -I -c 'import json, sys
f = sys.argv[1]; d = json.load(open(f))
for a in sys.argv[2:]:
    k, v = a.split("="); d[k] = int(v) * 1000
json.dump(d, open(f, "w"))' "$HOME/.claude/sessions/$P.json" "$@"
}
turn_end() {  # <epoch s> — back's last turn ended then: the registry row's idle stamp and the Stop hook's record
    row "statusUpdatedAt=$1"; mkdir -p "$SALA_BUSY_DIR"
    printf 'id=t\nepoch=%s\nseen=\nseen_status=idle\ntasks=0\ncrons=0\nflip=%s000\n' "$1" "$1" > "$SALA_BUSY_DIR/$U"
}
wrapdry() { SALA_IDLE_WRAPUP=on SALA_IDLE_SETTLE=0 "$SALA" watch --wrapup --dry-run 2>&1 | grep '^sala-test-back:'; }
printf 'sala-test-back\t%s\tsala-test-back\n' "$U" > "$SALA_SIDECAR"
row "startedAt=$(( $(date +%s) - 7200 ))"
reset; turn_end "$(( $(date +%s) - 3300 ))"; before=$(wrapdry)
pass >/dev/null; row "statusUpdatedAt=$(date +%s)"; after=$(wrapdry)   # asked, and the command moved the stamp
[ "$(asks back)" = 1 ] && has "$before" "the wrap-up would be typed now" && has "$after" "the wrap-up would be typed now" && ok "idle 55 minutes: wrapped up after a reload as before it" || bad "wrap: asked $(asks back); before '$before' after '$after'"
reset; turn_end "$(( $(date +%s) - 4200 ))"; before=$(wrapdry)
pass >/dev/null; row "statusUpdatedAt=$(date +%s)"; after=$(wrapdry)
[ "$(asks back)" = 1 ] && has "$before" "past the warm window" && has "$after" "past the warm window" && ok "idle past the maximum age: left alone after a reload as before it" || bad "warm window: asked $(asks back); before '$before' after '$after'"
turn_end "$(date +%s)"; after=$(wrapdry)
has "$after" "of 3000s — not yet" && ok "a turn that ends afterwards starts a new idle stretch" || bad "after a turn: '$after'"
rm -f "$SALA_BUSY_DIR/$U" "$SALA_SIDECAR"

echo "== --only: one named background agent, with the setting off"
reset; echo slow > "$TD/mode.back"
out=$(only back); rc=$?
[ "$rc" = 0 ] && [ "$(heard)" = back ] && has "$out" "sala-test-back: asked to reload (asked for by --only" && has "$out" "sala-test-back: the reload ran: Reloaded:" && ok "asked, waited for the answer, exit 0; nobody else asked" || bad "only ok: rc=$rc heard '$(heard)' $out"
echo ok > "$TD/mode.back"; out=$(only back); rc=$?
[ "$rc" = 0 ] && [ "$(asks back)" = 2 ] && ok "it asks a current pane too" || bad "only current: rc=$rc $out"
echo refused > "$TD/mode.back"; out=$(only back); rc=$?
[ "$rc" = 1 ] && has "$out" "the reload did not run" && ok "an answer that is no reload: exit 1" || bad "only refused: rc=$rc $out"
echo later > "$TD/mode.back"; out=$(WAIT=1 only back); rc=$?
[ "$rc" = 4 ] && has "$out" "no answer after 1s" && ok "no answer in time: exit 4" || bad "only later: rc=$rc $out"
printf '{"begun":%s000,"ok":true,"text":"Reloaded: later"}\n' "$(( $(date +%s) + 1 ))" > "$RUN/$U.reload.json"
out=$(dry --only sala-test-back); has "$out" "the reload ran: Reloaded: later" && [ -e "$RUN/$U.reload.json" ] && ok "--only --dry-run reads the late answer and leaves it" || bad "late: $out"
: > "$HEARD"
out=$(dry --only sala-test-back); rc=$?; [ "$rc" = 0 ] && has "$out" "would be asked to reload" && [ ! -s "$HEARD" ] && ok "--only --dry-run asks nobody" || bad "only dry: rc=$rc $out"
echo old > "$TD/mode.old"; out=$(only old); rc=$?; [ "$rc" = 1 ] && has "$out" "does not know reload" && ok "a mod without the verb: exit 1" || bad "only old: rc=$rc $out"
: > "$HEARD"
for c in "front|not a background agent" "side|not a background agent" "sdk|on the sdk lane" "nomod|no sala mod to ask" "nosuch|no tmux session"; do
    out=$(only "${c%%|*}"); rc=$?
    [ "$rc" = 1 ] && has "$out" "${c#*|}" && ok "--only ${c%%|*}: exit 1, ${c#*|}" || bad "only ${c%%|*}: rc=$rc $out"
done
[ ! -s "$HEARD" ] && ok "none of them was asked" || bad "asked: $(heard)"

echo "== a wrong argument"
for a in "--bogus" "--only" "--only --dry-run"; do
    out=$(SALA_PLUGIN_RELOAD=on "$SALA" watch --plugins $a 2>&1); rc=$?
    [ "$rc" = 2 ] && has "$out" "usage:" && [ ! -s "$HEARD" ] && ok "'$a' is refused (2)" || bad "$a: rc=$rc $out"
done

echo "== the config file, and the watch's own pass"
reset
printf 'SALA_PLUGIN_RELOAD=on\nSALA_PLUGIN_RELOAD_IDS="demo@demo-market"\n' > "$TD/config"
( unset SALA_PLUGIN_RELOAD_IDS; SALA_CONFIG="$TD/config" "$SALA" watch --plugins >/dev/null 2>&1 )
[ "$(asks back)" = 1 ] && ok "both settings are read from the config file" || bad "config: heard '$(heard)'; $(cat "$WLOG")"
reset; "$SALA" watch >/dev/null 2>&1
[ "$(asks back)" = 0 ] && ok "a watch pass with the setting off asks nobody" || bad "watch off: heard $(heard)"
SALA_PLUGIN_RELOAD=on "$SALA" watch >/dev/null 2>&1
[ "$(asks back)" = 1 ] && [ "$(asks front)" = 0 ] && ok "with it on, the watch asks the background agent" || bad "watch on: heard '$(heard)'; $(tail -20 "$WLOG")"

echo "== the state file"
[ "$(awk -F'\t' -v p="$(pid_of back):" 'index($1, p) == 1' "$STATE" | grep -c .)" = 1 ] && ok "one row per claude process" || bad "state: $(cat "$STATE")"
printf '999999:1\t0\t0\t-\t0\t0\t-\t-\t-\t0\t0\t0\n' >> "$STATE"; nap 0.3; deploy demo@demo-market "$HOME/.claude" 0 1.3.0; pass >/dev/null
grep -q '^999999:' "$STATE" && bad "a dead process's row stays: $(cat "$STATE")" || ok "a dead process's row goes at the next write"

exit "$fail"
