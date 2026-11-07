#!/usr/bin/env bash
# The operation queue's parallel rule (Wed Oct 28th 2026; lib/op.sh THE DRIVER AND THE PARALLEL RULE and op_tick_locked,
# lib/common.sh recycle_lock_shared): every verb declares in its own op_shape branch what it touches (OP_PAR, OP_KEYS); the tick starts, in
# one pass, as many queued operations as the declarations allow, at most SALA_OP_PARALLEL (3) at once. spawn, retire and rename are parallel
# (their names must not overlap); everything else, and any marker the table cannot parse, runs alone. What is checked guards the fleet's
# state from two operations at once, never the wording of a line:
#   · THE DECISIONS (the tick alone: markers written by hand, the units stand-in processes that sleep): par operations start together up to
#     the cap and not beyond; SALA_OP_PARALLEL=1 (and a bad value's default) is today's one at a time; two operations on one name run one
#     after the other, and a younger one on that name does not jump ahead of an older one that waits; a solo operation (a recycle, a lane
#     default, a retire of a registry name or the master, a rename of the master, a marker that fits no shape, a running marker of an older
#     sala with no class) waits for everything running, and while it waits, or runs, nothing younger starts; it is started when the way is clear.
#   · THE RACES (real runners on fakes: stub claude, tmux, systemd-run, systemctl, Slack, stackshot's pages.py / client / register hook; many
#     rounds with random small delays in every stub, ticks fired from every direction the product has — the enqueue's start of the watch, the
#     end-of-op kick, the timer — and two at once): in each round two spawns (a project agent with a TEXT mandate and a side session
#     about a board item) and a retire, and in some rounds a rename of a project agent, run side by side. After each, the pane map (every
#     row whole, no duplicate session or conversation, exactly the rows expected, each spawned row on its own fake's conversation), the
#     ledger log, the lane and model tables, the session registry (project, role, side fields; sessions.log empty of errors), the side
#     records and their mandate files, the markers (done, started <= ended, the class and names, in the archive), the Slack post and the
#     hearing session's line (one each, naming their own operation), the stub stackshot's logs (the register hook once per project agent with
#     its own conversation, pages.py and the client once per question) and the resurrect saves (never two at once) come out right and unmixed;
#     the shared recycle lock holds two runners and refuses a relaunch driver; the concurrency was real (two operations ran at the same time
#     in the rounds, never more than the cap); a solo operation after running ones starts after the last of them ended and blocks the
#     retire behind it; SALA_OP_PARALLEL=1 is serial end to end.
# Isolated HOME, a private tmux socket, the compiled fake claude (a wrapper gives each spawned fake its own conversation id and name).
# Usage: bash tests/opparallel.sh   (exit 0 = pass; SALA_OPPAR_ROUNDS=<n> sets the rounds of the race section, default 20; ~4 min)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_MASTER SALA_SET SALA_SET_SELF SALA_RECYCLE SALA_RETRY_WORKER SALA_LOCK_WHO SALA_LOCK_WAIT SALA_RELAUNCH_KIND \
      SALA_FLEET_HOSTS SALA_CGROUP_FILE SALA_OP_QUEUE SALA_OP_REBOOT SALA_OP_STUCK SALA_REBOOT_HOOKS SALA_NO_RELAUNCH SALA_SPAWN_REGISTER SALA_OP_PARALLEL \
      SALA_AGENT_CHECK SALA_AGENT_CHECK_SCRIPT SALA_SPAWN_ASK_CMD SALA_SPAWN_ASK_EVERY SALA_OP_FROM SALA_OP_WORDS SALA_OP_ID SALA_OP_PLAN SALA_OP_KICK_END
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"   # short timings, ok/bad/waitfor, fake_up, tmux_socket_rm; the lane variables unset
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC
exec {HOMELOCK}< "$HOME"; flock -x "$HOMELOCK"   # the temp folder is locked while the suite runs (systemd-tmpfiles' ageing skips a locked one)
ROUNDS=${SALA_OPPAR_ROUNDS:-20}
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect" "$HOME/real" "$HOME/wrap" "$HOME/units" "$HOME/pages/projects" "$HOME/work"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
mkdir -p "$HOME/.local/share/claude/versions"; cc -o "$HOME/.local/share/claude/versions/9.9.9" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (an EXIT trap may not exist yet here)
ln -s "$HOME/.local/share/claude/versions/9.9.9" "$HOME/.local/bin/claude"   # what a hand-made session types: `claude`
ln -s "$HOME/.local/share/claude/versions/9.9.9" "$HOME/real/claude"
# SALA_CLAUDE for the spawns: each spawned fake takes its own conversation id and name from its tmux session (the compiled fake reads one
# FAKE_SESSION_ID from its environment, which two spawns at once cannot set apart); exec'd as `claude`, so the process is named as the CLI's
cat > "$HOME/wrap/claude" <<'EOF'
#!/bin/bash
n=$(command tmux display -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null)
h=$(printf '%s' "$n" | md5sum); h=${h%% *}
export FAKE_NAME="$n" FAKE_SESSION_ID="${h:0:8}-${h:8:4}-4${h:13:3}-8${h:17:3}-${h:20:12}"
exec "$HOME/real/claude" "$@"
EOF
wuuid() { local h; h=$(printf '%s' "$1" | md5sum); h=${h%% *}; printf '%s' "${h:0:8}-${h:8:4}-4${h:13:3}-8${h:17:3}-${h:20:12}"; }   # <name> → the id the wrapper gives that name
# the units' stand-in. systemd-run: records the line; a sala-op-<id> unit's command runs detached in the queue's cgroup after a random
# small delay, its pid in units/<unit> (what `systemctl is-active` answers from); with $HOME/norun the unit is a sleeping process instead
# (the decisions section stands the runners in); an --on-active= request is the kick: refused while one of that name is pending (as
# systemd does), else a `watch --ops` a moment later. systemctl: is-active from units/, the watch service always inactive, and a start of
# sala-watch.service (what `sala op` does after queueing) runs a `watch --ops` at once, detached, as the service would
cat > "$HOME/.local/bin/systemd-run" <<'EOF'
#!/bin/bash
echo "$*" >> "$HOME/systemd-run.txt"
unit=$(sed -n 's/.*--unit=\([^ ]*\).*/\1/p' <<< "$*")
case " $* " in *" --on-active="*)
    all="$*"; n=${all#*--on-active=}; n=${n%% *}; [ "$n" -le 3 ] || n=2
    mkdir "$HOME/units/$unit.pending" 2>/dev/null || exit 1
    SALA_CGROUP_FILE="$HOME/op-unit.cgroup" setsid bash -c "sleep $n; rmdir '$HOME/units/$unit.pending'; exec '$SALA_BIN' watch --ops" 3>&- 9>&- </dev/null >/dev/null 2>&1 &
    exit 0 ;; esac
case "$*" in *--unit=sala-op-*) ;; *) exit 0;; esac
if [ -e "$HOME/norun" ]; then setsid sleep 600 3>&- 9>&- </dev/null >/dev/null 2>&1 & echo $! > "$HOME/units/$unit"; exit 0; fi
cmd="${@: -1}"
SALA_CGROUP_FILE="$HOME/op-unit.cgroup" setsid bash -c "sleep 0.\$((RANDOM % 3)); $cmd" 3>&- 9>&- </dev/null >/dev/null 2>&1 &
echo $! > "$HOME/units/$unit"
exit 0
EOF
echo "0::/user.slice/user-$EUID.slice/user@$EUID.service/app.slice/sala-op-1760000000-1.service" > "$HOME/op-unit.cgroup"
cat > "$HOME/.local/bin/systemctl" <<'EOF'
#!/bin/bash
echo "$*" >> "$HOME/systemctl.txt"
case "$*" in
    *is-active*sala-watch.service*) echo inactive; exit 3 ;;
    *is-active*) u=${@: -1}; p=$(cat "$HOME/units/$u" 2>/dev/null); [ -n "$p" ] && kill -0 "$p" 2>/dev/null && exit 0; exit 3 ;;
    *is-system-running*) echo running; exit 0 ;;
    *"start --no-block sala-watch.service"*) [ -e "$HOME/nowatch" ] && exit 0; SALA_CGROUP_FILE="$HOME/op-unit.cgroup" setsid "$SALA_BIN" watch --ops 3>&- 9>&- </dev/null >/dev/null 2>&1 & exit 0 ;;
    *) exit 0 ;;
esac
EOF
# sort: every read-modify-write of a table (the pane map's _ledger_apply, the lane and model tables' _lane_put, _model_put) sorts its result between
# the read and the replace, so a pause there is the widest window a second writer can fall into when the table is not locked
cat > "$HOME/.local/bin/sort" <<'EOF'
#!/bin/bash
sleep 0.$((RANDOM % 3))$((RANDOM % 10))
exec /usr/bin/sort "$@"
EOF
# the session registry (lib/sessions.py) reads sessions.json, changes it and writes it back: a pause at the write widens that window the same way
mkdir -p "$HOME/pysite"
cat > "$HOME/pysite/sitecustomize.py" <<'EOF'
import os, sys
if os.path.basename(sys.argv[0]) == "sessions.py":
    import json, random, time
    _dump = json.dump
    def _slow_dump(*a, **k):
        time.sleep(random.random() * 0.15)
        return _dump(*a, **k)
    json.dump = _slow_dump
EOF
export PYTHONPATH="$HOME/pysite${PYTHONPATH:+:$PYTHONPATH}"
chmod +x "$HOME/wrap/claude" "$HOME/.local/bin/systemd-run" "$HOME/.local/bin/systemctl" "$HOME/.local/bin/sort"
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.log"
POSTS="$HOME/posts.txt"; : > "$POSTS"
export SALA_NOTIFY_CMD="f=\$(cat); sleep 0.\$((RANDOM % 3)); printf '%s\n%%%%\n' \"\$f\" >> $POSTS"   # one write per post, '%%' after each; a random pause before it
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_CLAUDE="$HOME/wrap/claude"
export SALA_LIMIT_ALERT=off SALA_LIMIT_RESUME=off SALA_STUCK_POST=off SALA_OP_STUCK=off
export SALA_OP_POLL=1 SALA_OP_LOCK_WAIT=20 SALA_OP_KICK_END=1 SALA_RETRY_EVERY=2 SALA_RETRY_WINDOW=120
# the resurrect save (spawn runs it directly, retire and rename through `snapshot --now`): a stub that notes two runs at once
cat > "$HOME/fake-save.sh" <<'EOF'
#!/bin/bash
echo "save" >> "$HOME/save-runs.txt"
mkdir "$HOME/save.busy" 2>/dev/null || echo "overlap" >> "$HOME/save-overlap.txt"
sleep 0.$((RANDOM % 4))
rmdir "$HOME/save.busy" 2>/dev/null
exit 0
EOF
chmod +x "$HOME/fake-save.sh"; export SALA_RESURRECT_SAVE="$HOME/fake-save.sh"
# stackshot's side, stubbed. pages.py: resolve from $HOME/pages; agent-listed from listed.txt (key TAB name TAB line), gamma-foo-* names are not
# listed (the rename's client moves the entry); every call is logged as one line. client.py (rename's `post project-agent-rename`): logs its arguments
cat > "$HOME/fake-pages.py" <<'PY'
import os, random, sys, time
home = os.environ["HOME"]; cmd = sys.argv[1]; arg = sys.argv[2] if len(sys.argv) > 2 else ""
open(home + "/pages-calls.txt", "a").write(" ".join(sys.argv[1:]) + "\n")
time.sleep(random.random() * 0.3)
if cmd == "resolve":
    ex = os.path.exists(f"{home}/pages/{arg}.md"); print(arg, ex); sys.exit(0 if ex else 1)
if cmd == "agent-listed":
    listed = {}
    try:
        for ln in open(home + "/listed.txt"):
            if ln.strip(): k, n, m = ln.rstrip("\n").split("\t"); listed[n] = (k, m)
    except FileNotFoundError: pass
    if arg in listed: print(f"listed on {listed[arg][0]}: {listed[arg][1]}"); sys.exit(0)
    if arg.startswith("gamma-foo-"):
        print(f"not listed: {arg} is not under `agents:` on projects/foo (the page whose `display-name:` line is gamma-foo). The line `{arg}: <mandate>` has to be added there first (ask the project's -main agent), then the session can be made."); sys.exit(3)
    print("no project page for this name: nothing to check"); sys.exit(0)
sys.exit(1)
PY
cat > "$HOME/fake-client.py" <<'PY'
import json, os, random, sys, time
home = os.environ["HOME"]; a = sys.argv[1:]
open(home + "/client-calls.txt", "a").write(" ".join(a) + "\n")
time.sleep(random.random() * 0.3)
project, old, new = a[2], a[3], a[4]
open(home + "/listed.txt", "a").write("%s\t%s\t%s\n" % (project, new, "renamed by the stub"))
print(json.dumps({"project": "prj_example", "key": project, "result": "renamed", "old": old, "new": new, "front": True, "role": "x", "mandate": "renamed by the stub", "note": "stub"}))
PY
cat > "$HOME/fake-register" <<'EOF'
#!/bin/bash
# the register hook (SALA_SPAWN_REGISTER): one line per call, with the conversation the spawn found for the session
printf 'name=%s project=%s role=%s mfile=%s uuid=%s lane=%s\n' "$1" "$2" "$3" "$4" "${SALA_SPAWN_UUID:-}" "${SALA_SPAWN_LANE:-}" >> "$HOME/register.log"
sleep 0.$((RANDOM % 3))
exit 0
EOF
chmod +x "$HOME/fake-register"
python3 - "$HOME/projects.json" <<'PY'
import datetime, json, sys
d = {"schema": 1, "generated": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
     "projects": {"prj_example": {"id": "prj_example", "key": "projects/foo", "keeper": "gamma-foo-main", "agents": {
         "gamma-foo-main": {"front": True, "role": "main", "mandate_line": "the front door"}}}},
     "by_key": {"projects/foo": "prj_example"}}
json.dump(d, open(sys.argv[1], "w"))
PY
touch "$HOME/pages/projects/pt.md" "$HOME/pages/projects/foo.md"
export SALA_AGENT_CHECK_SCRIPT="$HOME/fake-pages.py" SALA_PROJECT_RECORD="$HOME/projects.json" SALA_STACKSHOT_CLIENT="$HOME/fake-client.py" SALA_SPAWN_ASK_CMD="" \
       SALA_SPAWN_REGISTER="$HOME/fake-register \"\$@\""
SALA="$ROOT/bin/salamander"; SOCK="sala-oppar-$$"; T="tmux -L $SOCK -f /dev/null"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # this server stands in for the fleet's
cleanup() {
    local p; for p in $(pgrep -f "salamander watch --ops|salamander op --run|sleep 600" 2>/dev/null); do grep -qz "HOME=$HOME" "/proc/$p/environ" 2>/dev/null && kill "$p" 2>/dev/null; done
    for p in "$HOME"/units/*; do [ -f "$p" ] && kill "$(<"$p")" 2>/dev/null; done
    $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    for p in $(pgrep -x claude); do [ "$HOME/.local/share/claude/versions/9.9.9" -ef "/proc/$p/exe" ] && kill -9 "$p" 2>/dev/null; done
    # whatever still runs on this HOME (a verb or its tee mid-write when the suite was stopped) would write the folder back after the rm
    for p in /proc/[0-9]*; do p=${p#/proc/}; [ "$p" = "$$" ] || [ "$p" = "$BASHPID" ] || ! grep -qz "^HOME=$HOME\$" "/proc/$p/environ" 2>/dev/null || kill -9 "$p" 2>/dev/null; done
    sleep 1; rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT; trap "exit 143" TERM INT HUP
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux    # literal socket: the children run set -u
. "$ROOT/lib/common.sh"; . "$ROOT/lib/op.sh"   # (op_line, op_shape: the suite reads the verbs' own declarations)
OPS="$SALA_STATE_DIR/ops"; DONE="$OPS/done"; SOCKLOG="$HOME/sock.log"; : > "$SOCKLOG"; TYPED="$HOME/typed.log"; MAP="$SALA_SIDECAR"
mval() { local f="$OPS/$1.op"; [ -f "$f" ] || f="$DONE/$1.op"; awk -F= -v k="$2" '$1==k {print substr($0, length(k)+2); exit}' "$f" 2>/dev/null; }
queued() { ls "$OPS"/*.op 2>/dev/null | wc -l; }
tick() { "$SALA" watch --ops >/dev/null 2>&1; }
hand() {  # <name> <uuid> — a session made by hand: a tmux session with a fake claude registered as that name and conversation
    $T new-session -d -s "$1" -c "$HOME/work" -e FAKE_SESSION_ID="$2" -e FAKE_NAME="$1" -e FAKE_LOG="$FAKE_LOG" -e FAKE_TYPED_LOG="$TYPED"; $T send-keys -t "$1" 'claude' Enter; }
regfile() { echo "$HOME/.claude/sessions/$(claude_pid_under "$(tmux display -p -t "$1" '#{pane_pid}')").json"; }
setname() { python3 - "$(regfile "$1")" "$2" <<'PY'
import json, sys; p = sys.argv[1]; d = json.load(open(p)); d["name"] = sys.argv[2]; json.dump(d, open(p, "w"))
PY
}
mapped() {  # <name> <uuid> — a pane-map row, a lane row and a model row for a live hand-made session
    ledger_write add "$1" "$2" "$1" "$HOME/work" && lane_write "$1" subscription-1 && model_write "$1" opus high; }
mkop() {  # <id> <verb> <arg>… — a queued marker written by hand (the decisions section)
    local i="$1" v="$2" a; shift 2
    { printf 'id=%s\ntime=%s\nfrom=sala-test-h\nwords=decisions test\nverb=%s\n' "$i" "${i%%-*}" "$v"; for a in "$@"; do printf 'arg=%s\n' "$a"; done; echo state=queued; } > "$OPS/$i.op"
}
st() { mval "$1" state; }   # <id> → its state
endunit() { local u="sala-op-$1" p; p=$(<"$HOME/units/$u") && kill "$p" 2>/dev/null; waitfor "! kill -0 $p 2>/dev/null" 20; }   # <id> — the stand-in unit ends (its process is killed)
setend() { local f="$OPS/$1.op"; [ -f "$f" ] && { _kv_set "$f" state "${2:-done}"; }; }
T_=$'\t'; ids=0; nextid() { ids=$((ids+1)); NID="$((1790000000 + ids))-$ids"; }   # → NID, a fresh marker id in queue order

echo "== setup: the hearing session h (its inbox logged) and two control sessions, each in the pane map with a lane and a model row"
$T new-session -d -s sala-test-h -c "$HOME/work" -e FAKE_SESSION_ID="$(uuid 1)" -e FAKE_NAME=sala-test-h -e FAKE_LOG="$FAKE_LOG" -e FAKE_SOCK_LOG="$SOCKLOG" -e FAKE_TYPED_LOG="$TYPED"; $T send-keys -t sala-test-h 'claude' Enter
hand sala-test-c1 "$(uuid 2)"; hand sala-test-c2 "$(uuid 3)"
fake_up sala-test-h sala-test-c1 sala-test-c2 || exit 1
tmux set-environment -g FAKE_LOG "$FAKE_LOG"; tmux set-environment -g FAKE_TYPED_LOG "$TYPED"   # what the spawned fakes inherit
mapped sala-test-h "$(uuid 1)"; mapped sala-test-c1 "$(uuid 2)"; mapped sala-test-c2 "$(uuid 3)"
[ "$(wc -l < "$MAP")" = 3 ] && ok "three rows in the pane map" || bad "map: $(slurp "$MAP")"

# ═══ THE DECISIONS ═════════════════════════════════════════════════════════════════════════════════════════════════════════════
touch "$HOME/norun"   # a started unit is a sleeping process: the tick's decisions can be read from the markers, no verb runs
k=30; for n in p1 p2 p3 p4; do k=$((k+1)); hand "sala-test-$n" "$(uuid $k)"; done   # four live sessions the decisions name (no verb runs there)
fake_up sala-test-p1 sala-test-p2 sala-test-p3 sala-test-p4 || exit 1
k=30; for n in p1 p2 p3 p4; do k=$((k+1)); ledger_write add "sala-test-$n" "$(uuid $k)" "sala-test-$n" "$HOME/work" >/dev/null 2>&1; done
clear_ops() { local f; for f in "$OPS"/*.op; do [ -e "$f" ] || continue; local i=${f##*/}; i=${i%.op}; [ -f "$HOME/units/sala-op-$i" ] && kill "$(<"$HOME/units/sala-op-$i")" 2>/dev/null; rm -f "$f" "$HOME/units/sala-op-$i"; done; rm -f "$OPS"/.launched.* 2>/dev/null; }
mkdir -p "$OPS"

echo "== the decisions: par operations start together, up to the cap, in one pass; the rest wait their turn"
clear_ops; nextid; D1=$NID; nextid; D2=$NID; nextid; D3=$NID; nextid; D4=$NID
mkop "$D1" spawn pa1 --project projects/pt --role front; mkop "$D2" retire sala-test-p1 --keep-web; mkop "$D3" rename sala-test-p2 sala-test-p2x; mkop "$D4" spawn pa4 --project projects/pt --role front
tick
[ "$(st "$D1")$(st "$D2")$(st "$D3")" = runningrunningrunning ] && [ "$(st "$D4")" = queued ] && ok "four par operations queued: the first three started in one tick (cap 3), the fourth waits" || bad "states: $(st "$D1") $(st "$D2") $(st "$D3") $(st "$D4")"
[ "$(mval "$D1" par)" = par ] && [ "$(mval "$D1" keys)" = pa1 ] && [ "$(mval "$D2" keys)" = sala-test-p1 ] && [ "$(mval "$D3" keys)" = "sala-test-p2 sala-test-p2x" ] && ok "the markers carry the class and the names the tick decided on (par=, keys=)" || bad "markers: $(cat "$OPS/$D1.op" "$OPS/$D3.op")"
tick; [ "$(st "$D4")" = queued ] && ok "a second tick with the cap reached starts nothing" || bad "D4 after a second tick: $(st "$D4")"
endunit "$D2"; setend "$D2" done; tick
[ "$(st "$D4")" = running ] && ok "one ended: the next tick starts the fourth" || bad "D4: $(st "$D4")"

echo "== SALA_OP_PARALLEL: 1 is one at a time (today's rule); a value that is no number is the default 3"
clear_ops; nextid; D1=$NID; nextid; D2=$NID; nextid; D3=$NID
mkop "$D1" spawn pa1 --project projects/pt --role front; mkop "$D2" spawn pa2 --project projects/pt --role front; mkop "$D3" spawn pa3 --project projects/pt --role front
SALA_OP_PARALLEL=1 tick; [ "$(st "$D1")" = running ] && [ "$(st "$D2")" = queued ] && [ "$(st "$D3")" = queued ] && ok "SALA_OP_PARALLEL=1: one running, two queued" || bad "cap 1: $(st "$D1") $(st "$D2") $(st "$D3")"
SALA_OP_PARALLEL=1 tick; [ "$(st "$D2")" = queued ] && ok "SALA_OP_PARALLEL=1: a second tick starts nothing while it runs" || bad "cap 1 again: $(st "$D2")"
clear_ops; nextid; D1=$NID; nextid; D2=$NID; nextid; D3=$NID; nextid; D4=$NID
mkop "$D1" spawn pa1 --project projects/pt --role front; mkop "$D2" spawn pa2 --project projects/pt --role front; mkop "$D3" spawn pa3 --project projects/pt --role front; mkop "$D4" spawn pa4 --project projects/pt --role front
SALA_OP_PARALLEL=abc tick; [ "$(st "$D3")" = running ] && [ "$(st "$D4")" = queued ] && ok "SALA_OP_PARALLEL=abc: the default 3" || bad "cap abc: $(st "$D3") $(st "$D4")"
clear_ops; nextid; D1=$NID; nextid; D2=$NID; nextid; D3=$NID
mkop "$D1" spawn pa1 --project projects/pt --role front; mkop "$D2" spawn pa2 --project projects/pt --role front; mkop "$D3" spawn pa3 --project projects/pt --role front
SALA_OP_PARALLEL=2 tick; [ "$(st "$D2")" = running ] && [ "$(st "$D3")" = queued ] && ok "SALA_OP_PARALLEL=2: two" || bad "cap 2: $(st "$D2") $(st "$D3")"

echo "== one name, one operation at a time: a second operation on a name waits, and a younger one on that name does not jump ahead of it"
clear_ops; nextid; D1=$NID; nextid; D2=$NID; nextid; D3=$NID; nextid; D4=$NID
mkop "$D1" retire sala-test-p1 --keep-web; mkop "$D2" retire sala-test-p1 --keep-web; mkop "$D3" rename sala-test-p1 sala-test-p1y; mkop "$D4" retire sala-test-p2 --keep-web
tick
[ "$(st "$D1")" = running ] && [ "$(st "$D2")" = queued ] && ok "two retires of one session: the first runs, the second waits (the queue accepts two of a verb; they must not run together)" || bad "same name: $(st "$D1") $(st "$D2")"
[ "$(st "$D3")" = queued ] && ok "a younger rename naming it waits behind the older retire that waits" || bad "younger on the name: $(st "$D3")"
[ "$(st "$D4")" = running ] && ok "an operation on another session starts beside the first" || bad "other session: $(st "$D4")"
endunit "$D1"; setend "$D1" done; tick
[ "$(st "$D2")" = running ] && [ "$(st "$D3")" = queued ] && ok "the first ended: the older waiting one starts, the younger still waits its turn" || bad "after the first: $(st "$D2") $(st "$D3")"

echo "== a solo operation (recycle) waits for all running ones and blocks the younger ones; once it runs, nothing starts beside it"
clear_ops; nextid; D1=$NID; nextid; D2=$NID; nextid; D3=$NID; nextid; D4=$NID
mkop "$D1" spawn pa1 --project projects/pt --role front; mkop "$D2" retire sala-test-p1 --keep-web; mkop "$D3" recycle --update --force; mkop "$D4" spawn pa4 --project projects/pt --role front
tick
[ "$(st "$D1")$(st "$D2")" = runningrunning ] && [ "$(st "$D3")" = queued ] && [ "$(st "$D4")" = queued ] && ok "two running: the recycle waits and the younger spawn waits behind it (not started beside the running ones, not past the recycle)" || bad "solo barrier: $(st "$D1") $(st "$D2") $(st "$D3") $(st "$D4")"
endunit "$D1"; setend "$D1" done; tick
[ "$(st "$D3")" = queued ] && [ "$(st "$D4")" = queued ] && ok "one of two ended: the recycle still waits for the other, the younger still waits" || bad "one ended: $(st "$D3") $(st "$D4")"
endunit "$D2"; setend "$D2" done; tick
[ "$(st "$D3")" = running ] && [ "$(mval "$D3" par)" = solo ] && [ "$(st "$D4")" = queued ] && ok "all ended: the recycle starts alone (par=solo); the younger spawn is not started beside it" || bad "solo start: $(st "$D3") $(mval "$D3" par) $(st "$D4")"
tick; [ "$(st "$D4")" = queued ] && ok "while the recycle runs a tick starts nothing" || bad "tick beside a solo: $(st "$D4")"
endunit "$D3"; setend "$D3" done; tick
[ "$(st "$D4")" = running ] && ok "the recycle ended: the younger spawn starts" || bad "after the solo: $(st "$D4")"

echo "== what runs alone: a lane default, a retire of a name the registry resolves (no tmux session of that name), a retire of the master, a rename of the master, a marker that fits no shape, a running marker with no class"
clear_ops; nextid; D1=$NID; nextid; D2=$NID
mkop "$D1" lane default subscription-1; mkop "$D2" spawn pa2 --project projects/pt --role front
tick; [ "$(st "$D1")" = running ] && [ "$(mval "$D1" par)" = solo ] && [ "$(st "$D2")" = queued ] && ok "lane default: alone (nothing starts beside it)" || bad "lane default: $(st "$D1") $(mval "$D1" par) $(st "$D2")"
clear_ops; nextid; D1=$NID; nextid; D2=$NID
mkop "$D1" spawn pa1 --project projects/pt --role front; mkop "$D2" retire some-registry-name --keep-web
tick; [ "$(st "$D1")" = running ] && [ "$(st "$D2")" = queued ] && ok "a retire of a name that is no tmux session or row (it would be resolved from the registry at run time): solo, waits for the spawn" || bad "registry retire: $(st "$D1") $(st "$D2")"
clear_ops; nextid; D1=$NID; nextid; D2=$NID
mkop "$D1" retire sala-test-p3 --keep-web; mkop "$D2" spawn pa2 --project projects/pt --role front
SALA_MASTER=sala-test-p3 tick; [ "$(st "$D1")" = running ] && [ "$(mval "$D1" par)" = solo ] && [ "$(st "$D2")" = queued ] && ok "the master's retire (unset first: a config write): solo" || bad "master retire: $(st "$D1") $(mval "$D1" par) $(st "$D2")"
clear_ops; nextid; D1=$NID; nextid; D2=$NID
mkop "$D1" rename sala-test-p3 sala-test-p3z; mkop "$D2" spawn pa2 --project projects/pt --role front
SALA_MASTER=sala-test-p3 tick; [ "$(st "$D1")" = running ] && [ "$(mval "$D1" par)" = solo ] && [ "$(st "$D2")" = queued ] && ok "the master's rename (master --set): solo" || bad "master rename: $(st "$D1") $(mval "$D1" par) $(st "$D2")"
clear_ops; nextid; D1=$NID; nextid; D2=$NID
mkop "$D1" retire; mkop "$D2" spawn pa2 --project projects/pt --role front
tick; [ "$(st "$D1")" = running ] && [ "$(mval "$D1" par)" = solo ] && [ "$(st "$D2")" = queued ] && ok "a marker that fits no shape: solo (it will be stuck at its own run, alone)" || bad "bad shape: $(st "$D1") $(mval "$D1" par) $(st "$D2")"
clear_ops; nextid; D1=$NID; nextid; D2=$NID
mkop "$D1" spawn pa1 --project projects/pt --role front; setend "$D1" running; echo "unit=sala-op-$D1" >> "$OPS/$D1.op"
setsid sleep 600 3>&- 9>&- </dev/null >/dev/null 2>&1 & echo $! > "$HOME/units/sala-op-$D1"
mkop "$D2" spawn pa2 --project projects/pt --role front
tick; [ "$(st "$D2")" = queued ] && ok "a running marker with no class (an older sala's): counted as solo, nothing starts beside it" || bad "old running marker: $(st "$D2")"
clear_ops; nextid; D1=$NID; nextid; D2=$NID
mkop "$D1" spawn pa1 --project projects/pt --role front; mkop "$D2" model sala-test-p4 opus
tick; [ "$(st "$D1")" = running ] && [ "$(st "$D2")" = queued ] && ok "model (it relaunches the pane under the exclusive recycle lock): solo, waits for the spawn" || bad "model: $(st "$D1") $(st "$D2")"
clear_ops; nextid; D1=$NID; nextid; D2=$NID
mkop "$D1" lane subscription-1 sala-test-p4; mkop "$D2" spawn pa2 --project projects/pt --role front
tick; [ "$(st "$D1")" = running ] && [ "$(mval "$D1" par)" = solo ] && [ "$(st "$D2")" = queued ] && ok "lane <lane> <session> (it relaunches the pane): solo" || bad "lane session: $(st "$D1") $(st "$D2")"
clear_ops; nextid; D1=$NID; nextid; D2=$NID
mkop "$D1" revive --only sala-test-p4 --force; mkop "$D2" spawn pa2 --project projects/pt --role front
tick; [ "$(st "$D1")" = running ] && [ "$(mval "$D1" par)" = solo ] && [ "$(st "$D2")" = queued ] && ok "revive: solo" || bad "revive: $(st "$D1") $(st "$D2")"
clear_ops; nextid; D1=$NID; nextid; D2=$NID
mkop "$D1" update; mkop "$D2" spawn pa2 --project projects/pt --role front
tick; [ "$(st "$D1")" = running ] && [ "$(mval "$D1" par)" = solo ] && [ "$(st "$D2")" = queued ] && ok "update: solo" || bad "update: $(st "$D1") $(st "$D2")"
clear_ops; nextid; D1=$NID; nextid; D2=$NID
mkop "$D1" provision; mkop "$D2" spawn pa2 --project projects/pt --role front
tick; [ "$(st "$D1")" = running ] && [ "$(mval "$D1" par)" = solo ] && [ "$(st "$D2")" = queued ] && ok "provision: solo" || bad "provision: $(st "$D1") $(st "$D2")"

echo "== a waiting operation holds its names against a younger one, and a solo one still starts past a waiting one (today's rule)"
clear_ops; nextid; D1=$NID; nextid; D2=$NID; nextid; D3=$NID
mkop "$D1" retire sala-test-p1 --keep-web; setend "$D1" waiting; mkop "$D2" rename sala-test-p1 sala-test-p1w; mkop "$D3" spawn pa3 --project projects/pt --role front
tick; [ "$(st "$D2")" = queued ] && [ "$(st "$D3")" = running ] && ok "waiting on a name: the younger operation on it waits, an unrelated one starts" || bad "waiting names: $(st "$D2") $(st "$D3")"
clear_ops; nextid; D1=$NID; nextid; D2=$NID
mkop "$D1" retire sala-test-p1 --keep-web; setend "$D1" waiting; mkop "$D2" recycle --force
tick; [ "$(st "$D2")" = running ] && ok "a solo operation starts past a waiting one (the queue went on past a waiting op before, too)" || bad "solo past waiting: $(st "$D2")"
clear_ops
for u in "$HOME"/units/*; do [ -f "$u" ] && kill "$(<"$u")" 2>/dev/null; done; rm -f "$HOME"/units/* "$HOME/norun"
for p in $(pgrep -f "sleep 600" 2>/dev/null); do grep -qz "^HOME=$HOME\$" "/proc/$p/environ" 2>/dev/null && kill "$p" 2>/dev/null; done; sleep 0.2   # this suite's own sleeps only (HOME is its temp dir): a bare pkill took another suite's `sleep 600` too (barepane)
for n in p1 p2 p3 p4; do $T kill-session -t "=sala-test-$n" 2>/dev/null; ledger_write retire "sala-test-$n" >/dev/null 2>&1; done

echo "== the shapes: each verb's own declaration (op_shape), read in one shell"
shapeof() { ( op_shape "$@" >/dev/null 2>&1; echo "$OP_PAR|$OP_LOCK|$OP_KEYS" ); }   # <verb> [args…] → class, lock, names (in a subshell)
SH=$(SALA_MASTER=sala-test-c1; shapeof spawn newone --project projects/pt --role front; shapeof spawn ptest-side-two --side --fork-of sala-test-c2; shapeof retire sala-test-c2; shapeof retire sala-test-c1; shapeof retire nosuch; shapeof rename sala-test-c2 zz; shapeof rename sala-test-c1 zz
    shapeof recycle; shapeof update; shapeof revive; shapeof lane default subscription-1; shapeof lane subscription-1 sala-test-c2; shapeof model sala-test-c2 opus; shapeof model sala-test-c2 --clear; shapeof provision)
SH=$(paste -sd';' - <<< "$SH")
EXP="par|share|newone;par|share|ptest-side-two sala-test-c2;par|share|sala-test-c2;solo|hold|;solo|hold|;par|share|sala-test-c2 zz;solo|hold|;solo|own|;solo|own|;solo|own|;solo|hold|;solo|own|;solo|own|;solo|hold|;solo|own|"
[ "$SH" = "$EXP" ] && ok "spawn (and a fork: its source too), retire of a live session and rename are par with the shared lock; the master's retire and rename, an unresolved retire, recycle, update, revive, lane, model and provision are solo" || bad "shapes: $SH"

# ═══ THE RACES ═════════════════════════════════════════════════════════════════════════════════════════════════════════════════
echo "== the races: $ROUNDS rounds of two spawns, a retire and (every third round) a rename, run side by side on fakes, with random delays in every stub"
CAPSEEN=0; OVERLAPS=0; VERBMAX=0; LOCKSEEN=0; LOCKEXCL=0
verbops() {  # → how many different operations have a verb process (not a dry run) running now: the operations really past the lock, side by side
    local p c e ids="" i
    for p in $(pgrep -f 'salamander (spawn|retire|rename|lane|model|revive|recycle) ' 2>/dev/null); do
        { c=$(tr '\0' ' ' < "/proc/$p/cmdline"); e=$(tr '\0' '\n' < "/proc/$p/environ"); } 2>/dev/null   # (a process gone between pgrep and the read is no process)
        case "$c" in *--dry-run*|*pgrep*|"") continue;; esac
        [[ $'\n'$e$'\n' == *$'\n'"HOME=$HOME"$'\n'* ]] || continue
        i=$(grep -m1 '^SALA_OP_ID=' <<< "$e") || continue
        case " $ids " in *" ${i#SALA_OP_ID=} "*) ;; *) ids="$ids ${i#SALA_OP_ID=}";; esac
    done
    echo $(echo $ids | wc -w)
}
waitops() {  # <ids…> → 0 when every marker is archived; sets WMAX (most running at once), WVERB (most with a verb process at once); samples the recycle lock's mode
    local id left cur i=0 t0=$SECONDS vb; WMAX=0; WVERB=0
    while :; do
        left=0; cur=0
        for id in "$@"; do [ -f "$OPS/$id.op" ] || continue; left=$((left+1)); [ "$(mval "$id" state)" = running ] && cur=$((cur+1)); done
        [ "$cur" -le "$WMAX" ] || WMAX=$cur
        vb=$(verbops); [ "$vb" -le "$WVERB" ] || WVERB=$vb
        if ! flock -n -x "$SALA_RECYCLE_LOCK" true 2>/dev/null; then LOCKSEEN=$((LOCKSEEN+1)); flock -n -s "$SALA_RECYCLE_LOCK" true 2>/dev/null || LOCKEXCL=$((LOCKEXCL+1)); fi
        [ "$left" = 0 ] && return 0
        [ $((SECONDS - t0)) -lt "$(scale 150)" ] || { echo "not finished after $((SECONDS - t0)) s: $(for id in "$@"; do echo -n "$id=$(mval "$id" state) "; done)"; return 1; }
        i=$((i+1)); if [ "${WAITTICKS:-1}" = 1 ] && [ $((i % 8)) = 0 ]; then tick & tick & wait; fi   # the timer's tick, two at once (WAITTICKS=0: none, the burst below lets only the end-of-op kick run the queue)
        nap 0.1
    done
}
lines_of() { P="$2" awk 'index($0, ENVIRON["P"]) {n++} END {print n+0}' "$1" 2>/dev/null; }   # <file> <needle> → how many lines hold it
mapcheck() {  # <expected session names…> → 0 when the pane map holds exactly those rows, each whole, with no duplicate session or conversation
    local want; want=$(printf '%s\n' "$@" | LC_ALL=C /usr/bin/sort | paste -sd, -)
    awk -F'\t' 'NF != 4 || $1 == "" || $2 == "" || $4 == "" {bad = 1} seen[$1]++ || useen[$2]++ {bad = 1} END {exit bad}' "$MAP" 2>/dev/null || return 1
    [ "$(cut -f1 "$MAP" | LC_ALL=C /usr/bin/sort | paste -sd, -)" = "$want" ]
}
tablecheck() {  # <file> <expected first-column names…> → whole lines (two or three fields), no duplicate key, exactly the expected keys
    local f="$1"; shift; local want; want=$(printf '%s\n' "$@" | LC_ALL=C /usr/bin/sort | paste -sd, -)
    awk -F'\t' 'NF < 2 || NF > 3 || $1 == "" || seen[$1]++ {bad = 1} END {exit bad}' "$f" 2>/dev/null || return 1
    [ "$(cut -f1 "$f" | LC_ALL=C /usr/bin/sort | paste -sd, -)" = "$want" ]
}
round() {  # <n> <with a rename: 0|1> — the fixtures, the operations, the wait, the checks; sets RFAIL
    local n=$1 four=$2 A B R S S2 UR US IDA IDB IDR IDS ops mx cap=3 id verb other
    A="ptest-a$n"; B="ptest-side-b$n"; R="sala-test-r$n"; S="gamma-foo-s$n"; S2="gamma-foo-t$n"; UR=$(uuid $((100 + n))); US=$(uuid $((200 + n)))
    printf 'projects/pt\t%s\ttext mandate of %s\n' "$A" "$A" >> "$HOME/listed.txt"
    hand "$R" "$UR"; fake_up "$R" || { bad "round $n: the retire target did not come up"; return; }
    ledger_write add "$R" "$UR" "$R" "$HOME/work"; lane_write "$R" subscription-1; model_write "$R" opus high
    if [ "$four" = 1 ]; then
        hand "$S" "$US"; fake_up "$S" || { bad "round $n: the rename target did not come up"; return; }
        setname "$S" "$S2"; ledger_write add "$S" "$US" "$S" "$HOME/work"; lane_write "$S" subscription-1; model_write "$S" sonnet; cap=4
    fi
    local KEEP=sala-test-c1,sala-test-c2,sala-test-h   # what the map holds again once the round's own sessions are gone
    local LANES_BEFORE MODELS_BEFORE; LANES_BEFORE=$(grep -E "^sala-test-(h|c1|c2)${T_}" "$SALA_LANES" | paste -sd'|' -); MODELS_BEFORE=$(grep -E "^sala-test-(h|c1|c2)${T_}" "$SALA_MODELS" | paste -sd'|' -)
    : > "$HOME/sock.log.round"; local sl0; sl0=$(wc -l < "$SOCKLOG" 2>/dev/null || echo 0)
    # the operations, queued one after the other as the hearers do; each enqueue starts a tick, as the service would
    enq spawn "$A" --project projects/pt --role front --lane subscription-1 --mandate "mandate-token-$A for the agent $A" --from sala-test-h --words "spawn $A"; IDA=$ID; [ "$RC" = 0 ] || { bad "round $n: enqueue $A: rc=$RC $OUT"; return; }
    enq spawn "$B" --side --project projects/pt --item "board#$((900 + n))" --agents "ptest-x,ptest-y" --lane subscription-1 --no-confirm --from sala-test-h --words "spawn $B"; IDB=$ID; [ "$RC" = 0 ] || { bad "round $n: enqueue $B: rc=$RC $OUT"; return; }
    enq retire "$R" --keep-web --from sala-test-h --words "retire $R"; IDR=$ID; [ "$RC" = 0 ] || { bad "round $n: enqueue retire $R: rc=$RC $OUT"; return; }
    ops="$IDA $IDB $IDR"
    if [ "$four" = 1 ]; then enq rename "$S" "$S2" --from sala-test-h --words "rename $S"; IDS=$ID; [ "$RC" = 0 ] || { bad "round $n: enqueue rename: rc=$RC $OUT"; return; }; ops="$ops $IDS"; fi
    # the wait: ticks from every direction (the enqueue's service start and the kick are the stubs'; waitops adds the timer's, sometimes two at once), sampled
    waitops $ops > "$HOME/wait.out" || { bad "round $n: $(<"$HOME/wait.out")"; return; }
    mx=$WMAX
    [ "$mx" -le "$cap" ] || bad "round $n: $mx operations were running at once, the cap is $cap"
    [ "$mx" -le "$CAPSEEN" ] || CAPSEEN=$mx
    [ "$WVERB" -le "$VERBMAX" ] || VERBMAX=$WVERB
    # ── the operations' own records
    local f ok_ops=1 s e
    for id in $ops; do
        verb=$(mval "$id" verb); s=$(mval "$id" started); e=$(mval "$id" ended)
        [ "$(mval "$id" state)" = done ] && [ -n "$(mval "$id" result)" ] && [ -n "$s" ] && [ -n "$e" ] && [ "$s" -le "$e" ] && [ "$(mval "$id" par)" = par ] && [ -f "$DONE/$id.op" ] && [ ! -f "$OPS/$id.op" ] || { ok_ops=0; bad "round $n: op $id ($verb): $(slurp "$DONE/$id.op")"; }
    done
    [ "$(mval "$IDA" keys)" = "$A" ] && [ "$(mval "$IDB" keys)" = "$B" ] && [ "$(mval "$IDR" keys)" = "$R" ] || { ok_ops=0; bad "round $n: the keys on the markers: $(mval "$IDA" keys) / $(mval "$IDB" keys) / $(mval "$IDR" keys)"; }
    local ov=0; for id in $ops; do for other in $ops; do [ "$id" \< "$other" ] || continue
        [ "$(mval "$id" started)" -le "$(mval "$other" ended)" ] && [ "$(mval "$other" started)" -le "$(mval "$id" ended)" ] && ov=$((ov+1)); done; done
    [ "$ov" -ge 1 ] && OVERLAPS=$((OVERLAPS+1)) || bad "round $n: no two operations overlapped in time ($(for id in $ops; do echo -n "$(mval "$id" started)-$(mval "$id" ended) "; done))"
    # ── the sessions the spawns made
    local ua ub; ua=$(wuuid "$A"); ub=$(wuuid "$B")
    tmux has-session -t "=$A" 2>/dev/null && tmux has-session -t "=$B" 2>/dev/null && ! tmux has-session -t "=$R" 2>/dev/null && ok_ops=$ok_ops || { ok_ops=0; bad "round $n: tmux sessions: $(tmux list-sessions -F '#{session_name}' | paste -sd' ' -)"; }
    local expect=(sala-test-h sala-test-c1 sala-test-c2 "$A" "$B"); if [ "$four" = 1 ]; then expect+=("$S2"); fi
    mapcheck "${expect[@]}" || { ok_ops=0; bad "round $n: the pane map: $(slurp "$MAP")"; }
    [ "$(awk -F'\t' -v s="$A" '$1==s {print $2}' "$MAP")" = "$ua" ] && [ "$(awk -F'\t' -v s="$B" '$1==s {print $2}' "$MAP")" = "$ub" ] || { ok_ops=0; bad "round $n: a spawned row is not on its own fake's conversation: $(grep -E "$A|$B" "$MAP")"; }
    if [ "$four" = 1 ]; then [ "$(awk -F'\t' -v s="$S2" '$1==s {print $2 "|" $3}' "$MAP")" = "$US|$S2" ] || { ok_ops=0; bad "round $n: the renamed row: $(grep -E "$S|$S2" "$MAP")"; }; fi
    for id in sala-test-h sala-test-c1 sala-test-c2; do [ "$(grep -c "^$id${T_}" "$MAP")" = 1 ] || { ok_ops=0; bad "round $n: control row $id: $(grep "^$id" "$MAP")"; }; done
    # the ledger log: one line per honored change, none refused or failed
    [ "$(lines_of "$SALA_LEDGER_LOG" "${T_}add${T_}$A${T_}")" = 1 ] && [ "$(lines_of "$SALA_LEDGER_LOG" "${T_}add${T_}$B${T_}")" = 1 ] && [ "$(lines_of "$SALA_LEDGER_LOG" "${T_}retire${T_}$R${T_}")" = 1 ] || { ok_ops=0; bad "round $n: the ledger log: $(grep -E "$A|$B|$R" "$SALA_LEDGER_LOG")"; }
    [ "$four" = 0 ] || [ "$(lines_of "$SALA_LEDGER_LOG" "${T_}rename${T_}$S${T_}")" = 1 ] || { ok_ops=0; bad "round $n: the ledger log for the rename: $(grep -E "$S" "$SALA_LEDGER_LOG")"; }
    ! grep -qE "refused|not written|failed" "$SALA_LEDGER_LOG" 2>/dev/null || { ok_ops=0; bad "round $n: the ledger log has a refusal: $(grep -E 'refused|not written|failed' "$SALA_LEDGER_LOG")"; }
    # the lane and model tables
    local lexp=(sala-test-h sala-test-c1 sala-test-c2 "$A" "$B"); [ "$four" = 0 ] || lexp+=("$S2")
    tablecheck "$SALA_LANES" "${lexp[@]}" || { ok_ops=0; bad "round $n: the lane table: $(slurp "$SALA_LANES")"; }
    [ "$(awk -F'\t' -v a="$A" -v b="$B" '$1==a || $1==b {print $2}' "$SALA_LANES" | paste -sd, -)" = "subscription-1,subscription-1" ] || { ok_ops=0; bad "round $n: the spawned lane rows: $(grep -E "$A|$B" "$SALA_LANES")"; }
    [ "$(grep -E "^sala-test-(h|c1|c2)${T_}" "$SALA_LANES" | paste -sd'|' -)" = "$LANES_BEFORE" ] || { ok_ops=0; bad "round $n: a control's lane row changed: $(slurp "$SALA_LANES")"; }
    local mexp=(sala-test-h sala-test-c1 sala-test-c2); [ "$four" = 0 ] || mexp+=("$S2")
    tablecheck "$SALA_MODELS" "${mexp[@]}" || { ok_ops=0; bad "round $n: the model table: $(slurp "$SALA_MODELS")"; }
    [ "$(grep -E "^sala-test-(h|c1|c2)${T_}" "$SALA_MODELS" | paste -sd'|' -)" = "$MODELS_BEFORE" ] || { ok_ops=0; bad "round $n: a control's model row changed: $(slurp "$SALA_MODELS")"; }
    [ "$four" = 0 ] || [ "$(awk -F'\t' -v s="$S2" '$1==s {print $2}' "$SALA_MODELS")" = sonnet ] || { ok_ops=0; bad "round $n: the renamed model row: $(grep -E "$S|$S2" "$SALA_MODELS")"; }
    ls "$SALA_LANES".t.* "$SALA_MODELS".t.* "$MAP".t.* "$MAP".tmp* 2>/dev/null | grep -q . && { ok_ops=0; bad "round $n: a temp file was left beside a table: $(ls "$SALA_LANES".t.* "$SALA_MODELS".t.* "$MAP".t.* 2>/dev/null)"; }
    # the session registry: the spawns' rows carry their project, role and side fields; no error was logged
    local reg; reg=$(python3 - "$SALA_SESSIONS_FILE" "$A" "$B" "$R" <<'PY'
import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception as e: print("unreadable: %s" % e); sys.exit(0)
rows = d.get("sessions", d) if isinstance(d, dict) else d
if isinstance(rows, dict): rows = list(rows.values())
by = {}
for r in rows:
    if r.get("name") in sys.argv[2:] and r.get("state", "live") == "live": by.setdefault(r["name"], []).append(r)
a, b, r = (by.get(x, []) for x in sys.argv[2:5])
out = []
out.append("A:%s/%s/%s" % (len(a), a[0].get("project") if a else "-", a[0].get("role") if a else "-"))
out.append("B:%s/%s/%s/%s" % (len(b), b[0].get("side") if b else "-", b[0].get("side_item") if b else "-", b[0].get("lane") if b else "-"))
out.append("R:%s" % len(r))
print(" ".join(out))
PY
)
    [ "$reg" = "A:1/projects/pt/front B:1/1/board#$((900 + n))/subscription-1 R:0" ] || { ok_ops=0; bad "round $n: the session registry: $reg"; }
    ! grep -q "error" "$SALA_SESSIONS_LOG" 2>/dev/null || { ok_ops=0; bad "round $n: sessions.log: $(slurp "$SALA_SESSIONS_LOG")"; }
    # the side record and the mandates
    [ "$(_kv_first "$SALA_SIDE_DIR/$B.side" name)" = "$B" ] && [ "$(_kv_first "$SALA_SIDE_DIR/$B.side" kind)" = discuss ] && [ "$(_kv_first "$SALA_SIDE_DIR/$B.side" item)" = "board#$((900 + n))" ] \
        && [ "$(_kv_first "$SALA_SIDE_DIR/$B.side" uuid)" = "$ub" ] && [ "$(_kv_first "$SALA_SIDE_DIR/$B.side" agents)" = "ptest-x,ptest-y" ] || { ok_ops=0; bad "round $n: the side record: $(slurp "$SALA_SIDE_DIR/$B.side")"; }
    grep -q "board#$((900 + n))" "$SALA_STATE_DIR/mandates/side-$B.md" 2>/dev/null && ! grep -q "$A" "$SALA_STATE_DIR/mandates/side-$B.md" || { ok_ops=0; bad "round $n: the side mandate: $(slurp "$SALA_STATE_DIR/mandates/side-$B.md" | head -5)"; }
    grep -q "mandate-token-$A for the agent $A" "$SALA_STATE_DIR/mandates/$IDA-$A.md" 2>/dev/null || { ok_ops=0; bad "round $n: the text mandate file: $(slurp "$SALA_STATE_DIR/mandates/$IDA-$A.md")"; }
    # what each pane was typed: its own mandate file, no other's
    [ "$(lines_of "$TYPED" "$ua <!-- sala --> Read $SALA_STATE_DIR/mandates/$IDA-$A.md")" = 1 ] && [ "$(lines_of "$TYPED" "$ua <!-- sala --> Read $SALA_STATE_DIR/mandates/side-$B.md")" = 0 ] \
        && [ "$(lines_of "$TYPED" "$ub <!-- sala --> Read $SALA_STATE_DIR/mandates/side-$B.md")" = 1 ] && [ "$(lines_of "$TYPED" "$ub <!-- sala --> Read $SALA_STATE_DIR/mandates/$IDA-$A.md")" = 0 ] || { ok_ops=0; bad "round $n: what the panes were typed: $(grep -E "$ua|$ub" "$TYPED" | cut -c1-160)"; }
    # stackshot's side: the register hook once for the project agent, with its own conversation and lane; pages.py asked once per spawn question (the plan, then the run)
    [ "$(lines_of "$HOME/register.log" "name=$A ")" = 1 ] && grep -qx "name=$A project=projects/pt role=front mfile=$SALA_STATE_DIR/mandates/$IDA-$A.md uuid=$ua lane=subscription-1" "$HOME/register.log" || { ok_ops=0; bad "round $n: the register hook: $(grep -E "$A" "$HOME/register.log")"; }
    [ "$(lines_of "$HOME/register.log" "$B")" = 0 ] || { ok_ops=0; bad "round $n: the register hook for the side session: $(grep "$B" "$HOME/register.log")"; }
    [ "$(lines_of "$HOME/pages-calls.txt" "agent-listed $A")" = 2 ] && [ "$(lines_of "$HOME/pages-calls.txt" "agent-listed $B")" = 0 ] || { ok_ops=0; bad "round $n: pages.py calls for the spawns: $(grep -E "$A|$B" "$HOME/pages-calls.txt" | paste -sd'|' -)"; }
    if [ "$four" = 1 ]; then
        [ "$(lines_of "$HOME/client-calls.txt" "post project-agent-rename projects/foo $S $S2")" = 1 ] || { ok_ops=0; bad "round $n: the stackshot client: $(grep -E "$S" "$HOME/client-calls.txt")"; }
        [ "$(lines_of "$HOME/pages-calls.txt" "agent-listed $S2")" -ge 1 ] || { ok_ops=0; bad "round $n: pages.py was not asked for $S2"; }
    fi
    ! awk '$0 !~ /^(resolve [a-z\/-]+|agent-listed [a-z0-9-]+)$/ {bad = 1} END {exit !bad}' "$HOME/pages-calls.txt" || { ok_ops=0; bad "round $n: a torn line in the pages.py log: $(grep -vE '^(resolve [a-z/-]+|agent-listed [a-z0-9-]+)$' "$HOME/pages-calls.txt" | head -3)"; }
    # the resurrect saves: never two at once
    [ ! -s "$HOME/save-overlap.txt" ] || { ok_ops=0; bad "round $n: two resurrect saves ran at once ($(wc -l < "$HOME/save-overlap.txt") times)"; }
    # the results: one Slack post and one line into the hearing session's inbox per operation, each naming its own operation
    local line np nl
    for id in $ops; do
        line=$(op_line "$id"); np=$(nposts "✅ *sala op: $line · done*"); nl=$(lines_of "$SOCKLOG" "[sala op $id] salamander $line "'\u2014'" done:")   # (the inbox logs the message as JSON)
        [ "$np" = 1 ] && [ "$nl" = 1 ] || { ok_ops=0; bad "round $n: op $id ($line): $np post(s), $nl inbox line(s) — $(grep -E "told|reply" "$SALA_LOG_DIR/salamander-op.log" | tail -4 | cut -c1-200) / $(tail -3 "$SOCKLOG" | cut -c1-200)"; }
    done
    [ "$(( $(wc -l < "$SOCKLOG") - sl0 ))" = "$(echo $ops | wc -w)" ] || { ok_ops=0; bad "round $n: the hearing session's inbox got $(( $(wc -l < "$SOCKLOG") - sl0 )) line(s) for $(echo $ops | wc -w) operations"; }
    ! grep -F "ptest-a$n" "$POSTS" | grep -vF "$A" >/dev/null || true
    [ "$ok_ops" = 1 ] && RFAIL=0 || RFAIL=1
    # leave the fleet as it was before the round's fixtures: the spawned sessions go, with their rows
    for id in "$A" "$B" ${four:+$S2}; do $T kill-session -t "=$id" 2>/dev/null; ledger_write retire "$id" >/dev/null 2>&1; lane_drop "$id"; model_drop "$id"; done
    [ "$(cut -f1 "$MAP" | LC_ALL=C /usr/bin/sort | paste -sd, -)" = "$KEEP" ] || RFAIL=1
}
RFAILS=0
: > "$HOME/pages-calls.txt"; : > "$HOME/register.log"; : > "$HOME/client-calls.txt"; rm -f "$HOME/save-overlap.txt" "$HOME/save-runs.txt"
for ((r=1; r<=ROUNDS; r++)); do
    RFAIL=0; round "$r" $(( r % 3 == 0 ? 1 : 0 )); [ "${RFAIL:-1}" = 0 ] && echo "  round $r ok" || { RFAILS=$((RFAILS+1)); echo "  round $r FAILED"; }
    [ "$fail" = 0 ] || break
done
[ "$RFAILS" = 0 ] && [ "$fail" = 0 ] && ok "$ROUNDS rounds: the pane map, tables, registry, side records, markers, results and stackshot logs came out right and unmixed every time" || bad "$RFAILS round(s) failed"
[ "$CAPSEEN" -ge 3 ] && ok "the concurrency was real: up to $CAPSEEN operations were running at once, never more than the cap" || bad "at most $CAPSEEN operations were ever running at once"
[ "$VERBMAX" -ge 2 ] && ok "and $VERBMAX verb processes of different operations ran at the same moment (not runners waiting for a lock)" || bad "at most $VERBMAX verb process(es) at once: the operations did not really run side by side"
[ "$LOCKSEEN" -ge 1 ] && [ "$LOCKEXCL" = 0 ] && ok "the recycle lock was held in $LOCKSEEN samples, and always shared (a shared try succeeded each time)" || bad "recycle lock samples: held $LOCKSEEN, not shareable $LOCKEXCL"
[ "$OVERLAPS" = "$ROUNDS" ] && ok "operations overlapped in time in every round" || bad "overlap in $OVERLAPS of $ROUNDS rounds"
[ "$(wc -l < "$HOME/save-runs.txt" 2>/dev/null || echo 0)" -ge "$ROUNDS" ] && ok "the resurrect save ran $(wc -l < "$HOME/save-runs.txt") times, none overlapping another" || bad "saves: $(slurp "$HOME/save-runs.txt" | wc -l)"

# ═══ THE SHARED LOCK, A SOLO OPERATION AFTER RUNNING ONES, ONE AT A TIME, A BURST ═════════════════════════════════════════════════
gone() { local x; for x in "$@"; do $T kill-session -t "=$x" 2>/dev/null; ledger_write retire "$x" >/dev/null 2>&1; lane_drop "$x"; model_drop "$x"; done; }   # <session…> — a section's own sessions, and their rows, go
done_ok() { [ "$(mval "$1" state)" = done ] && [ -f "$DONE/$1.op" ]; }

echo "== the recycle lock: any number of shared holders at once; a relaunch driver (exclusive) is refused while one holds it, and a shared taker while a driver does"
rm -f "$HOME/lk1" "$HOME/lk2" "$HOME/lk3"
( recycle_lock_shared lt1 5 >/dev/null 2>&1 && : > "$HOME/lk1"; sleep 6 ) & LP1=$!
( recycle_lock_shared lt2 5 >/dev/null 2>&1 && : > "$HOME/lk2"; sleep 6 ) & LP2=$!
waitfor '[ -e "$HOME/lk1" ] && [ -e "$HOME/lk2" ]' 40 && ok "two shared holders at once" || bad "shared holders: lk1=$([ -e "$HOME/lk1" ] && echo y || echo n) lk2=$([ -e "$HOME/lk2" ] && echo y || echo n)"
( recycle_lock lt3 0 ) >/dev/null 2>&1; rc=$?; [ "$rc" = 1 ] && ok "an exclusive taker (a relaunch driver) is refused while they hold it" || bad "exclusive taker: rc=$rc"
recycle_locked && ok "recycle_locked (the watch steps that stand aside for a relaunch) reads locked" || bad "recycle_locked: not locked"
wait "$LP1" "$LP2"
( recycle_lock lt4 0 >/dev/null 2>&1 && : > "$HOME/lk3"; sleep 4 ) & LP3=$!
waitfor '[ -e "$HOME/lk3" ]' 40 && ( recycle_lock_shared lt5 0 ) >/dev/null 2>&1; rc=$?; [ "$rc" = 1 ] && ok "a shared taker is refused while a relaunch driver holds it" || bad "shared taker beside a driver: rc=$rc"
wait "$LP3"; ( recycle_lock lt6 0 ) >/dev/null 2>&1; rc=$?; [ "$rc" = 0 ] && ok "all released: an exclusive taker gets it" || bad "after release: rc=$rc"

echo "== a solo operation behind running ones, with real runners: it starts after the last of them ended, and the retire queued behind it after it"
SN="ptest-a-solo"; RN="sala-test-rs"; printf 'projects/pt\t%s\ttext mandate\n' "$SN" >> "$HOME/listed.txt"
hand "$RN" "$(uuid 301)"; fake_up "$RN" && { ledger_write add "$RN" "$(uuid 301)" "$RN" "$HOME/work"; lane_write "$RN" subscription-1; }
enq spawn "$SN" --project projects/pt --role front --mandate "solo test mandate" --from sala-test-h --words "spawn $SN"; I1=$ID
enq lane default subscription-1 --from sala-test-h --words "lane default subscription-1"; I2=$ID
enq retire "$RN" --keep-web --from sala-test-h --words "retire $RN"; I3=$ID
waitops "$I1" "$I2" "$I3" > "$HOME/wait.out" || bad "$(<"$HOME/wait.out")"
done_ok "$I1" && done_ok "$I2" && done_ok "$I3" && ok "the spawn, the lane default and the retire all ended done" || bad "states: $(mval "$I1" state) / $(mval "$I2" state) $(mval "$I2" result) / $(mval "$I3" state) $(mval "$I3" result)"
[ "$(mval "$I2" par)" = solo ] && [ "$(mval "$I2" started)" -ge "$(mval "$I1" ended)" ] && ok "the lane default (solo) started after the running spawn ended ($(mval "$I1" ended) <= $(mval "$I2" started))" || bad "solo start: spawn ended $(mval "$I1" ended), lane started $(mval "$I2" started) par=$(mval "$I2" par)"
[ "$(mval "$I3" started)" -ge "$(mval "$I2" ended)" ] && ok "the retire queued behind it started after it ended ($(mval "$I2" ended) <= $(mval "$I3" started)), though it could have run beside the spawn" || bad "behind the solo: lane ended $(mval "$I2" ended), retire started $(mval "$I3" started)"
[ "$WVERB" -le 1 ] && ok "no two verb processes ran at once through it" || bad "verb processes at once: $WVERB"
gone "$SN"

echo "== SALA_OP_PARALLEL=1 end to end: the same three operations run one after the other, never two at once"
export SALA_OP_PARALLEL=1
PA="ptest-a-ser1"; PB="ptest-a-ser2"; RN="sala-test-rt"; printf 'projects/pt\t%s\ttext mandate\nprojects/pt\t%s\ttext mandate\n' "$PA" "$PB" >> "$HOME/listed.txt"
hand "$RN" "$(uuid 302)"; fake_up "$RN" && { ledger_write add "$RN" "$(uuid 302)" "$RN" "$HOME/work"; lane_write "$RN" subscription-1; }
enq spawn "$PA" --project projects/pt --role front --mandate "serial test one" --from sala-test-h --words "spawn $PA"; I1=$ID
enq spawn "$PB" --project projects/pt --role front --mandate "serial test two" --from sala-test-h --words "spawn $PB"; I2=$ID
enq retire "$RN" --keep-web --from sala-test-h --words "retire $RN"; I3=$ID
waitops "$I1" "$I2" "$I3" > "$HOME/wait.out" || bad "$(<"$HOME/wait.out")"
done_ok "$I1" && done_ok "$I2" && done_ok "$I3" && ok "all three ended done" || bad "states: $(mval "$I1" state) $(mval "$I2" state) $(mval "$I3" state)"
[ "$(mval "$I1" par)" = par ] && [ "$WMAX" = 1 ] && [ "$WVERB" -le 1 ] && ok "at most one running at a time (sampled: $WMAX running, $WVERB verb process)" || bad "serial: WMAX=$WMAX WVERB=$WVERB"
[ "$(mval "$I2" started)" -ge "$(mval "$I1" ended)" ] && [ "$(mval "$I3" started)" -ge "$(mval "$I2" ended)" ] && ok "each started after the one before it ended, in queue order" || bad "order: $(mval "$I1" started)-$(mval "$I1" ended) / $(mval "$I2" started)-$(mval "$I2" ended) / $(mval "$I3" started)-$(mval "$I3" ended)"
unset SALA_OP_PARALLEL; gone "$PA" "$PB"

echo "== two retires of one session (the queue accepts two of a verb): one after the other, the second finding the first's result"
RN="sala-test-ru"; hand "$RN" "$(uuid 303)"; fake_up "$RN" && { ledger_write add "$RN" "$(uuid 303)" "$RN" "$HOME/work"; lane_write "$RN" subscription-1; }
enq retire "$RN" --keep-web --from sala-test-h --words "retire $RN"; I1=$ID
enq retire "$RN" --keep-web --from sala-test-h --words "retire $RN again"; I2=$ID
waitops "$I1" "$I2" > "$HOME/wait.out" || bad "$(<"$HOME/wait.out")"
done_ok "$I1" && [ -n "$I2" ] && [ -f "$DONE/$I2.op" ] && [ "$WMAX" = 1 ] && [ "$(mval "$I2" started)" -ge "$(mval "$I1" ended)" ] \
    && ok "same session, same verb: never at once ($(mval "$I1" started)-$(mval "$I1" ended), then $(mval "$I2" started)-$(mval "$I2" ended); the second ended $(mval "$I2" state))" || bad "same name: $(mval "$I1" state) $(mval "$I2" state) WMAX=$WMAX / $(mval "$I1" started)-$(mval "$I1" ended) $(mval "$I2" started)-$(mval "$I2" ended)"

echo "== a burst of five spawns: three at a time, the others as the first ones end, every session whole and its own"
# Only the end-of-op kick may start the two that wait behind the cap. Any other tick (the service the enqueue starts, the timer's, the ones waitops
# fires) can start them inside an ending operation's finish window instead -- its state is already done, its slot free, its marker not yet archived --
# and then no operation sees one queued at its end, and no kick is asked for. That is the queue working, not a defect, so the burst is run with no
# other tick: the five are queued before any starts, one tick starts three, and the last two can only follow the kick (SALA_OP_KICK_END=1 here).
waitfor '! ls "$HOME"/units/*.pending >/dev/null 2>&1' 60   # a one-off tick requested by an earlier section is not still due
BN=(); for k in 1 2 3 4 5; do BN+=("ptest-a-burst$k"); printf 'projects/pt\tptest-a-burst%s\ttext mandate\n' "$k" >> "$HOME/listed.txt"; done
: > "$HOME/systemd-run.txt"; BI=(); touch "$HOME/nowatch"
for k in 1 2 3 4 5; do enq spawn "${BN[k-1]}" --project projects/pt --role front --mandate "burst mandate $k" --from sala-test-h --words "spawn ${BN[k-1]}"; BI+=("$ID"); done
rm -f "$HOME/nowatch"; tick
WAITTICKS=0 waitops "${BI[@]}" > "$HOME/wait.out" || bad "$(<"$HOME/wait.out")"
ALLOK=1; for k in 0 1 2 3 4; do done_ok "${BI[k]}" || ALLOK=0; done
[ "$ALLOK" = 1 ] && ok "all five ended done" || bad "states: $(for k in 0 1 2 3 4; do echo -n "$(mval "${BI[k]}" state) "; done)"
[ "$WMAX" = 3 ] && ok "three were running at once, never four" || bad "most running at once: $WMAX"
mapcheck sala-test-h sala-test-c1 sala-test-c2 "${BN[@]}" && ok "the pane map holds the five new rows and the controls, whole" || bad "map: $(slurp "$MAP")"
BOK=1; for k in 1 2 3 4 5; do [ "$(awk -F'\t' -v s="ptest-a-burst$k" '$1==s {print $2}' "$MAP")" = "$(wuuid "ptest-a-burst$k")" ] || BOK=0; done
[ "$BOK" = 1 ] && ok "each row is on its own fake's conversation" || bad "burst rows: $(grep burst "$MAP")"
[ "$(grep -c 'sala-op-kick-end' "$HOME/systemd-run.txt")" -ge 1 ] && ok "an op that ended with others queued asked for the follow-up tick (sala-op-kick-end)" || bad "no kick: $(slurp "$HOME/systemd-run.txt" | head -3)"
[ ! -s "$HOME/save-overlap.txt" ] && ok "no two resurrect saves at once in any section" || bad "save overlaps: $(wc -l < "$HOME/save-overlap.txt")"
gone "${BN[@]}"

[ "$fail" = 0 ] && echo "opparallel: pass" || echo "opparallel: FAIL"
exit $fail
