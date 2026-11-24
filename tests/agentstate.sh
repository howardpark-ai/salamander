#!/usr/bin/env bash
# The agent-state snapshot (lib/agentstate.py, lib/heartbeat.sh "agent-state.json", docs/stackshot-contracts.md interface 38): the heartbeat writes
# <live store>/<letter>/agent-state.json, one entry per live or sleeping row of the session registry (state busy | idle | unknown, since, why, pane, read,
# subagents), and hands it to stackshot with SALA_AGENT_STATE_POST_CMD. stackshot's own `running()` decides which subagents run: here a STUB stackshot checkout
# (a tiny package with running() and Unreadable, SALA_STACKSHOT_CHECKOUT) plays it, and a stub post command plays the server. What is checked:
#  - the decision: a turn pane is busy; an idle pane with a running subagent is busy; an idle pane with none is idle; a quiet subagent is dropped for an idle or shell pane
#    and kept for a turn pane; an unreadable one counts only while its meta file is fresh (an idle pane) or always (a turn pane); a sleeping agent is idle; running() raising
#    Unreadable gives unknown with read false; a dialog open, no live pane and two live rows of one name give unknown; a retired row is no agent; `text` is dropped, a brief is
#    cut at 2048 bytes on a character boundary; `running` is asked for the pane's own conversation and the transcript roots;
#  - the file: the keys in the contract's order, written on every run (`written` moves), `since` kept while the state is the same and set to the pane's stamp when the pane
#    flipped, atomic, never in the store repo's commit, nothing written with SALA_AGENT_STATE=off, no post for --no-push, nothing written for --dry-run (counts only on stderr);
#  - the post: the file's path is the command's last argument and the posted bytes are the file; the default command is the stackshot client's `post agent-state --file`;
#    a failing, not-ok, missing or slow command logs ONE line per five minutes and never fails the heartbeat; a slow one is stopped after SALA_AGENT_STATE_TIMEOUT with its
#    process group;
#  - an import failure of stackshot's module writes nothing new (the last good file stays) and logs one line;
#  - a body over the limit has its briefs shortened (longest first, to 512 bytes, then to none), no agent or state dropped, one log line;
#  - the contract text, the settings in config.example;
#  - PARITY with stackshot's own audit: when stackshot's checkout and its virtualenv are on this machine (SALA_PARITY_STACKSHOT, else SALA_STACKSHOT_DIR, else ~/stackshot),
#    the same fixtures (real transcript folders, real registry rows) are run through the heartbeat and through stackshot's `_mover_subagents` (audit_ticks); the subagents
#    each lists, and busy against idle, must be the same. A divergence fails. Without the checkout (CI, a test box with no stackshot) the section is skipped, said in its line.
# SAFETY: HOME is a mktemp -d held with flock and removed on exit; no tmux, no claude, no network; the "panes" are bash subshells held on a fifo (released on exit, never killed
# by name); the heartbeat runs with no fleet hosts; no git user key is set (identity through the environment, in the sandbox repo only).
# Usage: bash tests/agentstate.sh   (exit 0 = pass)
set -u
unset TMUX TMUX_PANE XDG_STATE_HOME SALA_MASTER SALA_SLEEP_DIR SALA_FLEET_HOSTS SALA_SESSIONS_FILE SALA_SIDECAR SALA_STATE_DIR SALA_SESSION_URL SALA_AGENT_STATE SALA_AGENT_STATE_POST_CMD \
      SALA_STACKSHOT_CHECKOUT SALA_STACKSHOT_CLIENT SALA_AGENT_STATE_TRANSCRIPTS SALA_AGENT_STATE_TIMEOUT SALA_AGENT_STATE_MAX_BODY SALA_HEARTBEAT_STATE_DIR SALA_HEARTBEAT_REPO SALA_HEARTBEAT_DIR
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
REAL_HOME=$HOME; REAL_SS=${SALA_PARITY_STACKSHOT:-${SALA_STACKSHOT_DIR:-$REAL_HOME/stackshot}}; unset SALA_STACKSHOT_DIR
SANDBOX=""; NHOLD=40; HOLD=""; pids=()
release() {   # the held "panes" end by themselves when their fifo gets a line each (no kill)
    [ -n "$HOLD" ] && [ -p "$HOLD" ] && [ "${#pids[@]}" -gt 0 ] && { printf '\n%.0s' $(seq "$NHOLD") > "$HOLD" 2>/dev/null; wait 2>/dev/null; }
    pids=(); true
}
cleanup() { release; [ -z "$SANDBOX" ] || { exec 8<&-; rm -rf "$SANDBOX" 2>/dev/null; }; true; }; trap cleanup EXIT   # set before the temp folder exists
SANDBOX=$(mktemp -d); export HOME=$SANDBOX SALA_CONFIG=/dev/null SALA_TZ=Asia/Seoul
case "$HOME" in /tmp/*|"${TMPDIR:-/tmp}"/*) ;; *) echo "agentstate: HOME is not a temporary directory ($HOME) - refusing to run"; exit 1;; esac
exec 8< "$SANDBOX"; flock -n 8 2>/dev/null   # systemd-tmpfiles' ageing skips a directory held with flock
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects" "$HOME/.local/share/tmux/resurrect"
export SALA_AUTO_UPDATE=off SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" PYTHONDONTWRITEBYTECODE=1 SALA_STACKSHOT_PASS=off
SALA="$ROOT/bin/salamander"
. "$ROOT/lib/common.sh"
export REG="$SALA_SESSIONS_FILE" MAP="$SALA_SIDECAR" SLP="$SALA_SLEEP_DIR"
mkdir -p "$SLP"
JQ() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(eval(sys.argv[1]), sort_keys=True))' "$1"; }   # JQ <python expr over d> < json
HOLD="$HOME/hold"; mkfifo "$HOLD"
for _ in $(seq "$NHOLD"); do ( exec 3<>"$HOLD"; read -t 900 -u 3 _x ) & pids+=($!); done   # live pids for the registry rows: each ends when it reads its line

# ---- the stub checkout (stackshot's audit/subagent_tie.py reduced to running() and Unreadable) and the stub post command -----------------------------
STUB="$HOME/stub"; mkdir -p "$STUB/stackshot/audit"
: > "$STUB/stackshot/__init__.py"; : > "$STUB/stackshot/audit/__init__.py"
cat > "$STUB/stackshot/audit/subagent_tie.py" <<'PY'
import json, os
RUNNING_S = 5400.0
class Unreadable(Exception):
    pass
def running(session, roots, now):
    with open(os.environ["STUB_CALLS"], "a") as f:
        f.write(json.dumps([session, list(roots)]) + "\n")
    v = json.load(open(os.environ["STUB_RUNNING"])).get(session, [])
    if v == "unreadable":
        raise Unreadable("no transcript of the session on this box")
    return v
PY
cat > "$HOME/push.sh" <<'SH'
#!/bin/bash
# the stub of the post command: the file's path is its last argument; its mode is in push.mode
echo "$#:${*: -1}" >> "$HOME/push.calls"
case "$(cat "$HOME/push.mode" 2>/dev/null || echo ok)" in
    ok) cp "${@: -1}" "$HOME/pushed.json"; echo '{"ok":true,"agents":3}' ;;
    fail) echo "[404] not found" >&2; exit 1 ;;
    notok) echo '{"ok":false,"error":"schema"}'; exit 0 ;;
    slow) echo $$ > "$HOME/push.pid"; exec sleep 60 ;;
esac
SH
chmod +x "$HOME/push.sh"

# ---- the fixtures: registry rows, the CLI's live rows, markers, and what the stub's running() answers (mode stub) or real transcript folders (mode real) --------------
cat > "$HOME/mk.py" <<'PY'
import json, os, sys, time
mode = sys.argv[1]; pids = [int(x) for x in sys.argv[2:]]
home = os.environ["HOME"]; now = int(time.time())
def u(i): return "%08x-0000-4000-8000-%012x" % (i, i)
def sub(i, **kw):
    d = {"id": i, "description": "d-" + i, "brief": "b-" + i, "text": "d-%s\nb-%s" % (i, i), "at": now - 60}
    d.update(kw); return d
rows, cli, markers, stub = [], [], [], {}
def agent(i, name, pane, subs=None, state="live", extra_rows=()):
    rows.append({"id": "11111111-aaaa-4000-8000-%012x" % i, "name": name, "project": None, "role": None, "lane": "subscription-1", "model": "opus", "effort": "high", "pane": name,
                 "cwd": "/w/" + name, "machine": "q", "created": "2026-11-20T00:00:%02dZ" % (i % 60), "state": state, "retired_at": "2026-11-21T01:00:00Z" if state == "retired" else None,
                 "aliases": [], "transcripts": [{"id": u(i), "machine": "q", "at": "2026-11-20T00:00:00Z", "why": "add"}]})
    if pane == "sleep":
        markers.append((u(i), name))
    elif pane:
        cli.append({"pid": pids.pop(0), "sessionId": u(i), "name": name, "cwd": "/w/" + name, "kind": "interactive", "status": pane, "statusUpdatedAt": (now - 3600) * 1000,
                    "tmux": name + ":@1.%1", "bridgeSessionId": "session_" + name})
    if subs is not None:
        stub[u(i)] = subs
if mode == "stub":
    long_brief = "a" + "\u20ac" * 1000       # 1 + 3000 bytes: the cut at 2048 lands inside a character
    agent(1, "a-turn", "busy", [])
    agent(2, "a-idlesub", "idle", [sub("s2")])
    agent(3, "a-idle", "idle", [])
    agent(4, "a-quietidle", "idle", [sub("s4", quiet=True, at=now - 9000)])
    agent(5, "a-quietturn", "busy", [sub("s5", quiet=True, at=now - 9000)])
    agent(6, "a-unrdold", "shell", [{"id": "s6", "text": "", "at": 0.0, "unreadable": True, "meta_at": now - 7200}])
    agent(7, "a-unrdfresh", "idle", [{"id": "s7", "text": "", "at": 0.0, "unreadable": True, "meta_at": now - 60}])
    agent(8, "a-unrdnometa", "idle", [{"id": "s8", "text": "", "at": 0.0, "unreadable": True}])
    agent(9, "a-sleep", "sleep", [])
    agent(10, "a-unreadable", "idle", "unreadable")
    agent(11, "a-waiting", "waiting", [])
    agent(12, "a-nopane", None, [])
    agent(13, "a-long", "busy", [sub("s13", brief=long_brief)])
    agent(14, "a-dup", "idle", []); agent(15, "a-dup", None, [])
    agent(16, "a-retired", None, [], state="retired")
    agent(17, "a-shell", "shell", [])
else:
    cats = ["none", "fresh", "quiet", "dead", "finished", "unrd_old", "unrd_fresh", "unrd_bad"]
    i = 100
    for pane in ("busy", "idle", "shell"):
        for c in cats:
            i += 1; agent(i, "p-%s-%s" % (pane, c), pane)
            proj = os.path.join(home, ".claude", "projects", "proj"); os.makedirs(proj, exist_ok=True)
            tr = os.path.join(proj, u(i) + ".jsonl")
            with open(tr, "w") as f: f.write(json.dumps({"type": "user", "message": {"content": "hello"}}) + "\n")
            if c == "none": continue
            sd = os.path.join(proj, u(i), "subagents"); os.makedirs(sd, exist_ok=True)
            mp, tp = os.path.join(sd, "agent-x%d.meta.json" % i), os.path.join(sd, "agent-x%d.jsonl" % i)
            age = {"fresh": 60, "quiet": 10800, "dead": 25200, "finished": 60, "unrd_old": 7200, "unrd_fresh": 60, "unrd_bad": 60}[c]
            with open(mp, "w") as f: f.write("{" if c == "unrd_bad" else json.dumps({"description": "work " + c, **({"finished": True} if c == "finished" else {})}))
            if c not in ("unrd_old", "unrd_fresh"):
                with open(tp, "w") as f: f.write(json.dumps({"type": "user", "message": {"content": "brief of " + c}}) + "\n")
            for p in (mp, tp):
                if os.path.exists(p): os.utime(p, (now - age, now - age))
for r in cli:
    with open(os.path.join(home, ".claude", "sessions", "%d.json" % r["pid"]), "w") as f: json.dump(r, f)
json.dump({"schema": 1, "written": "2026-11-21T00:00:00Z", "sessions": {r["id"]: r for r in rows}}, open(os.environ["REG"], "w"), indent=2)
with open(os.environ["MAP"], "w") as f:
    for r in rows:
        if any(m[1] == r["name"] for m in markers): f.write("%s\t%s\t%s\t%s\n" % (r["name"], r["transcripts"][0]["id"], r["name"], r["cwd"]))
os.makedirs(os.environ["SLP"], exist_ok=True)
for uu, name in markers:
    with open(os.path.join(os.environ["SLP"], uu), "w") as f: f.write("2026-11-22T06:10:00Z %s\n" % name)
json.dump(stub, open(os.path.join(home, "stub-running.json"), "w"))
PY
LIVE="$HOME/hb"; AS="$LIVE/q/agent-state.json"; LOGD="$HOME/.claude"; ASLOG="$LOGD/salamander-agent-state.log"
export STUB_RUNNING="$HOME/stub-running.json" STUB_CALLS="$HOME/stub-calls"
hb() {   # hb [heartbeat args] → output; CK and PUSHCMD override the stub checkout and the post command (an empty PUSHCMD = no post)
    env SALA_HEARTBEAT_STATE_DIR="$LIVE" SALA_HEARTBEAT_GIT=off SALA_HEARTBEAT_LETTER=q SALA_HEARTBEAT_NAME=sbox SALA_SESSIONS=write \
        SALA_STACKSHOT_CHECKOUT="${CK:-$STUB}" SALA_AGENT_STATE_POST_CMD="${PUSHCMD-$HOME/push.sh}" ${HBENV:-} "$SALA" heartbeat "$@" 2>&1
}
logn() { [ -f "$ASLOG" ] && wc -l < "$ASLOG" || echo 0; }
agent_q() { JQ "d['agents']['$1']$2" < "$AS"; }   # agent_q <name> <python subscript/expression tail>

echo "== the decision, from stub fixtures"
python3 "$HOME/mk.py" stub "${pids[@]}"; echo ok > "$HOME/push.mode"
out=$(hb); rc=$?
[ "$rc" = 0 ] && [ -s "$AS" ] && ok "the heartbeat wrote agent-state.json" || bad "heartbeat rc=$rc: $out"
r=$(JQ '[d["schema"], type(d["written"]).__name__, abs(d["written"] - __import__("time").time()) < 120, sorted(d["agents"])]' < "$AS")
[ "$r" = '[1, "int", true, ["a-dup", "a-idle", "a-idlesub", "a-long", "a-nopane", "a-quietidle", "a-quietturn", "a-shell", "a-sleep", "a-turn", "a-unrdfresh", "a-unrdnometa", "a-unrdold", "a-unreadable", "a-waiting"]]' ] \
    && ok "schema 1, written is a whole epoch second, one entry per live or sleeping row (a retired row is none; two rows of one name are one entry)" || bad "head: $r"
r=$(JQ 'list(d["agents"]["a-turn"])' < "$AS")
[ "$r" = '["state", "since", "why", "pane", "read", "subagents"]' ] && ok "an entry's keys are the contract's (state, since, why, pane, read, subagents)" || bad "keys: $r"
r=$(python3 - "$AS" "$ROOT/lib" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[2]); import agentstate
d = json.load(open(sys.argv[1]))
print(all(list(a) == list(agentstate.ENTRY_KEYS) for a in d["agents"].values()), list(agentstate.ENTRY_KEYS) == ["state", "since", "why", "pane", "read", "subagents"])
PY
)
[ "$r" = "True True" ] && ok "every entry has exactly agentstate.ENTRY_KEYS, in that order (the one place the list is kept)" || bad "ENTRY_KEYS: $r"
chk() { # <agent> <expected "state pane read nsubs"> <label>
    local got; got=$(JQ '[d["agents"]["'"$1"'"][k] for k in ("state", "pane", "read")] + [len(d["agents"]["'"$1"'"]["subagents"])]' < "$AS" | tr -d '[],"' | tr -s ' ' | sed 's/true/T/;s/false/F/')
    [ "$got" = "$2" ] && ok "$3" || bad "$3: got '$got', wanted '$2'"
}
chk a-turn "busy turn T 0" "a pane in a turn is busy, with no subagent"
chk a-idlesub "busy idle T 1" "an idle pane with a running subagent is busy"
chk a-idle "idle idle T 0" "an idle pane and no subagent is idle"
chk a-shell "idle shell T 0" "a shell pane (turn over, a background task) and no subagent is idle, its pane named shell"
chk a-quietidle "idle idle T 0" "a quiet subagent is dropped for an idle pane (idle)"
chk a-quietturn "busy turn T 1" "a quiet subagent is kept for a turn pane (busy)"
[ "$(agent_q a-quietturn '["subagents"][0].get("quiet")')" = true ] && ok "…and still says quiet" || bad "quiet flag lost"
chk a-unrdold "idle shell T 0" "an unreadable subagent whose meta file is 2 hours old is dropped for a shell pane"
chk a-unrdfresh "busy idle T 1" "an unreadable subagent with a fresh meta file counts for an idle pane (busy)"
[ "$(agent_q a-unrdfresh '["subagents"][0]["unreadable"]')" = true ] && [ "$(agent_q a-unrdfresh '["subagents"][0].get("meta_at") is not None')" = true ] && ok "…carrying unreadable and meta_at" || bad "unreadable flags"
chk a-unrdnometa "busy idle T 1" "an unreadable subagent with no meta_at is kept (as the audit keeps it)"
chk a-sleep "idle sleeping T 0" "a sleeping agent is idle, its pane sleeping"
chk a-unreadable "unknown idle F 0" "Unreadable gives unknown with read false and no subagents"
chk a-waiting "unknown unknown F 0" "a pane whose status is a dialog (waiting) is unknown, never idle"
chk a-nopane "unknown unknown F 0" "a live row with no live claude and no marker is unknown"
chk a-dup "unknown unknown F 0" "two live rows of one name make the name unknown"
r=$(JQ '[sorted(s) for s in d["agents"]["a-idlesub"]["subagents"]][0]' < "$AS")
[ "$r" = '["at", "brief", "description", "id"]' ] && ok "a subagent carries id, description, brief and at (text is dropped; no flag that does not hold)" || bad "subagent keys: $r"
r=$(JQ '[d["agents"]["a-idlesub"]["subagents"][0][k] for k in ("id", "description", "brief")]' < "$AS")
[ "$r" = '["s2", "d-s2", "b-s2"]' ] && ok "the words are running()'s own" || bad "words: $r"
r=$(python3 - "$AS" <<'PY'
import json, sys
b = json.load(open(sys.argv[1]))["agents"]["a-long"]["subagents"][0]["brief"]
e = b.encode("utf-8"); print(len(e), len(b), e.decode("utf-8") == b)
PY
)
[ "$r" = "2047 683 True" ] && ok "a brief of 3001 bytes is cut to 2047 (2048, minus the character the limit would split), valid UTF-8" || bad "brief cut: $r"
r=$(python3 - "$STUB_CALLS" "$HOME" <<'PY'
import json, sys
calls = [json.loads(l) for l in open(sys.argv[1])]
home = sys.argv[2]
asked = sorted(c[0][:8] for c in calls)
print(sorted(set(tuple(c[1]) for c in calls)) == [(home + "/.claude/projects", home + "/.claude-team/projects")], len(calls), not any(a in asked for a in ("0000000b", "0000000c", "0000000e", "0000000f", "00000010")))
PY
)
[ "$r" = "True 12 True" ] && ok "running() was asked once for each readable pane's own conversation (12), with the box's two transcript roots, and never for a dialog, a missing pane, a duplicate or a retired row" || bad "calls: $r"
r=$(JQ '[a["why"] for n, a in sorted(d["agents"].items()) if n in ("a-turn", "a-idlesub", "a-idle", "a-sleep", "a-unreadable")]' < "$AS")
[ "$r" = '["no turn, no subagents", "no turn; 1 subagent running", "asleep, no subagents", "in a turn", "transcript not readable on this box"]' ] && ok "why is one plain line" || bad "why: $r"
[ "$(cat "$HOME/pushed.json" 2>/dev/null | wc -c)" = "$(wc -c < "$AS")" ] && same_file "$AS" "$HOME/pushed.json" && ok "the post got the file's own bytes (stub command, path as last argument)" || bad "pushed differs"
[ "$(tail -1 "$HOME/push.calls" | cut -d: -f2-)" = "$AS" ] && ok "the command's last argument is the file's path" || bad "push args: $(tail -1 "$HOME/push.calls")"
[ ! -e "$ASLOG" ] && ok "a clean run logs nothing" || bad "log: $(cat "$ASLOG")"
ls -a "$LIVE/q" | grep -q 'agent-state.json.*tmp' && bad "a temp file was left beside the file" || ok "no temp file left beside it (atomic write)"

echo "== since: kept while the state holds, the pane's stamp when it flipped"
r1=$(JQ '[d["written"], sorted(set(a["since"] for a in d["agents"].values()))]' < "$AS")
[ "$r1" = "$(JQ '[d["written"], [d["written"]]]' < "$AS")" ] && ok "first run: every since is written" || bad "first since: $r1"
cp "$AS" "$HOME/as.1"; sleep 1.3
python3 - "$HOME" <<'PY'
import glob, json, sys, time
for f in glob.glob(sys.argv[1] + "/.claude/sessions/*.json"):
    d = json.load(open(f))
    if d["name"] == "a-turn":
        d["status"] = "idle"; d["statusUpdatedAt"] = int(time.time() * 1000); json.dump(d, open(f, "w")); open(sys.argv[1] + "/flip.stamp", "w").write(str(int(d["statusUpdatedAt"] / 1000)))
PY
hb >/dev/null
w1=$(JQ 'd["written"]' < "$HOME/as.1"); w2=$(JQ 'd["written"]' < "$AS")
[ "$w2" -gt "$w1" ] && ok "written moves on every run ($w1 → $w2)" || bad "written: $w1 $w2"
r=$(python3 - "$HOME/as.1" "$AS" "$(cat "$HOME/flip.stamp")" <<'PY'
import json, sys
a, b = json.load(open(sys.argv[1]))["agents"], json.load(open(sys.argv[2]))["agents"]; stamp = int(sys.argv[3])
same = all(a[n]["since"] == b[n]["since"] for n in a if n != "a-turn")
print(same, b["a-turn"]["state"], b["a-turn"]["since"] == stamp, a["a-turn"]["since"] != stamp)
PY
)
[ "$r" = "True idle True True" ] && ok "unchanged agents keep their since; a-turn went busy → idle and its since is the pane's own stamp" || bad "since: $r"

echo "== --dry-run writes nothing and shows counts only; --no-push writes and posts nothing"
cp "$AS" "$HOME/as.2"; n=$(wc -l < "$HOME/push.calls"); sleep 1.1
out=$(hb --dry-run)
same_file "$AS" "$HOME/as.2" && has "$out" "== agent-state: 15 agents: " && ! has "$out" "b-s2" && ok "dry run: the file is untouched; one line of counts, no brief in the output" || bad "dry: $out"
out=$(hb --no-push); [ "$(wc -l < "$HOME/push.calls")" = "$n" ] && ! same_file "$AS" "$HOME/as.2" && ok "--no-push rewrites the file (written moves) and posts nothing" || bad "no-push: calls $(wc -l < "$HOME/push.calls") vs $n"

echo "== SALA_AGENT_STATE=off writes and posts nothing"
rm -f "$AS"; n=$(wc -l < "$HOME/push.calls")
out=$(HBENV="SALA_AGENT_STATE=off" hb); rc=$?
[ "$rc" = 0 ] && [ ! -e "$AS" ] && [ "$(wc -l < "$HOME/push.calls")" = "$n" ] && [ -s "$LIVE/q/session-registry.json" ] && ok "off: no file, no post, the other files as before" || bad "off: rc=$rc $(ls "$LIVE/q")"

echo "== an import failure keeps the last good file and logs one line"
hb >/dev/null; cp "$AS" "$HOME/as.3"; : > "$ASLOG"; rm -f "$LOGD"/salamander-agent-state.*.mark; sleep 1.1
out=$(CK="$HOME/no-such-checkout" hb); rc=$?
[ "$rc" = 0 ] && same_file "$AS" "$HOME/as.3" && ok "no checkout: the heartbeat succeeds and the file is byte for byte the last good one" || bad "no checkout: rc=$rc"
[ "$(logn)" = 1 ] && grep -q "last good file stays" "$ASLOG" && ok "one log line says so" || bad "log: $(cat "$ASLOG")"
BAD="$HOME/stub-bad"; mkdir -p "$BAD/stackshot/audit"; : > "$BAD/stackshot/__init__.py"; : > "$BAD/stackshot/audit/__init__.py"; echo "raise RuntimeError('broken')" > "$BAD/stackshot/audit/subagent_tie.py"
out=$(CK="$BAD" hb); rc=$?
[ "$rc" = 0 ] && same_file "$AS" "$HOME/as.3" && [ "$(logn)" = 1 ] && ok "a module that raises on import: same, and not logged again inside five minutes" || bad "bad module: rc=$rc log=$(logn)"
touch -d '10 minutes ago' "$LOGD"/salamander-agent-state.import.mark; out=$(CK="$BAD" hb)
[ "$(logn)" = 2 ] && ok "after five minutes the next failure logs again" || bad "log lines: $(logn)"

echo "== the post: a failure logs once per five minutes and never fails the heartbeat"
: > "$ASLOG"; rm -f "$LOGD"/salamander-agent-state.*.mark; echo fail > "$HOME/push.mode"
out=$(hb); rc=$?
[ "$rc" = 0 ] && [ "$(logn)" = 1 ] && grep -q "exited 1" "$ASLOG" && ok "a command that exits 1: the heartbeat exits 0, one line (with the command's own words)" || bad "fail: rc=$rc log=$(cat "$ASLOG")"
out=$(hb); [ "$(logn)" = 1 ] && ok "a second failure inside five minutes logs nothing" || bad "second: $(logn)"
touch -d '10 minutes ago' "$LOGD"/salamander-agent-state.post.mark; out=$(hb)
[ "$(logn)" = 2 ] && ok "five minutes later it logs again" || bad "third: $(logn)"
echo notok > "$HOME/push.mode"; touch -d '10 minutes ago' "$LOGD"/salamander-agent-state.post.mark; out=$(hb); rc=$?
[ "$rc" = 0 ] && [ "$(logn)" = 3 ] && grep -q "answer was not ok" "$ASLOG" && ok "an answer that is JSON with ok not true is a failure, logged" || bad "notok: rc=$rc $(tail -1 "$ASLOG")"
echo ok > "$HOME/push.mode"; touch -d '10 minutes ago' "$LOGD"/salamander-agent-state.post.mark; out=$(hb)
[ "$(logn)" = 3 ] && ok "a good answer ({ok: true}) logs nothing" || bad "good: $(logn)"
out=$(PUSHCMD="$HOME/no-such-command" hb); rc=$?
touch -d '10 minutes ago' "$LOGD"/salamander-agent-state.post.mark; out=$(PUSHCMD="$HOME/no-such-command" hb); rc2=$?
[ "$rc" = 0 ] && [ "$rc2" = 0 ] && grep -q "cannot start" "$ASLOG" && ok "a command that does not exist: logged, heartbeat exits 0" || bad "missing: $rc $rc2 $(tail -1 "$ASLOG")"
n=$(wc -l < "$HOME/push.calls"); out=$(PUSHCMD="" hb); [ "$(wc -l < "$HOME/push.calls")" = "$n" ] && [ -s "$AS" ] && ok "an empty SALA_AGENT_STATE_POST_CMD: the file is written, nothing is posted" || bad "empty cmd"

echo "== the post: a slow command is stopped after SALA_AGENT_STATE_TIMEOUT, process group and all"
: > "$ASLOG"; rm -f "$LOGD"/salamander-agent-state.*.mark; echo slow > "$HOME/push.mode"; rm -f "$HOME/push.pid"
t0=$SECONDS; out=$(HBENV="SALA_AGENT_STATE_TIMEOUT=2" hb); rc=$?; dt=$((SECONDS - t0))
[ "$rc" = 0 ] && [ "$dt" -lt 40 ] && ok "the heartbeat returned (rc 0) after ${dt}s, the command's 60 s cut at 2" || bad "slow: rc=$rc dt=$dt"
grep -q "longer than 2" "$ASLOG" && ok "one line names the timeout" || bad "timeout log: $(cat "$ASLOG")"
sp=$(cat "$HOME/push.pid" 2>/dev/null || echo 0)
[ "$sp" -gt 1 ] && ! kill -0 "$sp" 2>/dev/null && ok "the command's process is gone (its group was stopped)" || bad "the slow command (pid $sp) is still running"
echo ok > "$HOME/push.mode"

echo "== the default post command is the stackshot client's \`post agent-state --file <path>\`"
cat > "$HOME/client.py" <<'PY'
import json, os, sys
open(os.environ["HOME"] + "/client.argv", "w").write(json.dumps(sys.argv[1:]))
print('{"ok":true,"agents":3}')
PY
out=$(env -u SALA_AGENT_STATE_POST_CMD SALA_HEARTBEAT_STATE_DIR="$LIVE" SALA_HEARTBEAT_GIT=off SALA_HEARTBEAT_LETTER=q SALA_HEARTBEAT_NAME=sbox SALA_SESSIONS=write \
    SALA_STACKSHOT_CHECKOUT="$STUB" SALA_STACKSHOT_CLIENT="$HOME/client.py" "$SALA" heartbeat 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(cat "$HOME/client.argv" 2>/dev/null)" = "[\"post\", \"agent-state\", \"--file\", \"$AS\"]" ] && ok "the client got: post agent-state --file <the file>, through stackshot_form.py" || bad "default cmd: rc=$rc argv=$(cat "$HOME/client.argv" 2>/dev/null) $out"
rm -f "$HOME/client.argv"; : > "$ASLOG"; rm -f "$LOGD"/salamander-agent-state.*.mark
out=$(env -u SALA_AGENT_STATE_POST_CMD SALA_HEARTBEAT_STATE_DIR="$LIVE" SALA_HEARTBEAT_GIT=off SALA_HEARTBEAT_LETTER=q SALA_HEARTBEAT_NAME=sbox SALA_SESSIONS=write \
    SALA_STACKSHOT_CHECKOUT="$STUB" SALA_STACKSHOT_CLIENT="$HOME/none.py" "$SALA" heartbeat 2>&1); rc=$?
[ "$rc" = 0 ] && [ -s "$AS" ] && [ ! -e "$HOME/client.argv" ] && ok "no stackshot client on the box: the file is written, no post, no failure" || bad "no client: rc=$rc"

echo "== the body limit: briefs shortened longest first (512, then none); no agent, state or subagent dropped"
python3 - "$HOME" <<'PY'
import json, sys
home = sys.argv[1]
d = json.load(open(home + "/stub-running.json")); u = lambda i: "%08x-0000-4000-8000-%012x" % (i, i)
d[u(1)] = [{"id": "big%d" % k, "description": "d", "brief": "x" * (2000 if k % 2 else 300), "text": "", "at": 1} for k in range(200)]
json.dump(d, open(home + "/stub-running.json", "w"))
PY
out=$(hb); full=$(wc -c < "$AS")
[ "$full" -gt 150000 ] && ok "fixture: the full body is $full bytes (200 subagents on one agent)" || bad "fixture too small: $full"
: > "$ASLOG"; rm -f "$LOGD"/salamander-agent-state.*.mark; lim=$((full - 20000))
out=$(HBENV="SALA_AGENT_STATE_MAX_BODY=$lim" hb); rc=$?; a=$(wc -c < "$AS")
r=$(JQ '[len(d["agents"]), len(d["agents"]["a-turn"]["subagents"]), sorted(set(len(s["brief"]) for s in d["agents"]["a-turn"]["subagents"]))]' < "$AS")
[ "$rc" = 0 ] && [ "$a" -le "$lim" ] && [ "$r" = "[15, 200, [300, 512, 2000]]" ] && ok "a little over: only the longest briefs went to 512 bytes (the 300 ones and the rest of the 2000 ones are as they were); 15 agents and 200 subagents all there ($a of $lim)" || bad "stage 1: rc=$rc size=$a r=$r"
[ "$(logn)" = 1 ] && grep -q "briefs were shortened" "$ASLOG" && ok "one log line says the briefs were shortened" || bad "shrink log: $(cat "$ASLOG")"
out=$(HBENV="SALA_AGENT_STATE_MAX_BODY=70000" hb); a=$(wc -c < "$AS")
r=$(JQ '[len(d["agents"]), len(d["agents"]["a-turn"]["subagents"]), max(len(s["brief"]) for s in d["agents"]["a-turn"]["subagents"]) <= 512, min(len(s["brief"]) for s in d["agents"]["a-turn"]["subagents"]), d["agents"]["a-turn"]["state"], d["agents"]["a-idle"]["state"], d["agents"]["a-unreadable"]["state"]]' < "$AS")
[ "$a" -le 70000 ] && [ "$r" = '[15, 200, true, 0, "busy", "idle", "unknown"]' ] && ok "a tight limit: every long brief to 512, then the longest left to none until it fits ($a of 70000); every agent, subagent and state intact" || bad "stage 2: size=$a r=$r"
out=$(hb)
r=$(JQ 'max(len(s["brief"].encode()) for a in d["agents"].values() for s in a["subagents"])' < "$AS"); [ "$r" = 2047 ] && ok "under the limit nothing is shortened (the next run: briefs back, the longest 2047 bytes)" || bad "after: $r"

echo "== the file is never in the store repo's commit"
STORE="$HOME/store"; git init -q "$STORE" 2>/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
rm -rf "$LIVE"
out=$(env SALA_HEARTBEAT_STATE_DIR="$LIVE" SALA_HEARTBEAT_GIT=full SALA_HEARTBEAT_REPO="$STORE" SALA_HEARTBEAT_DIR=board SALA_HEARTBEAT_LETTER=q SALA_HEARTBEAT_NAME=sbox SALA_SESSIONS=write \
    SALA_STACKSHOT_CHECKOUT="$STUB" SALA_AGENT_STATE_POST_CMD="$HOME/push.sh" "$SALA" heartbeat --no-push 2>&1); rc=$?
files=$(git -C "$STORE" ls-files | tr '\n' ' '); lastc=$(git -C "$STORE" show --stat --format=%s HEAD 2>/dev/null | tr '\n' ' ')
[ "$rc" = 0 ] && [ -s "$AS" ] && ok "git mode full: agent-state.json is in the live store" || bad "git mode: rc=$rc"
has "$files" "board/q/sessions.json" && ! has "$files$lastc" "agent-state" && ok "the commit holds the store's files and not agent-state.json (tracked: $files)" || bad "tracked: $files / $lastc"
[ -z "$(git -C "$STORE" status --porcelain | grep agent-state)" ] && ok "and the repo has no untracked agent-state.json" || bad "untracked in the repo"
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

echo "== the contract text and the settings"
C="$ROOT/docs/stackshot-contracts.md"
cv=$(sed -n 3p "$C"); cvn=${cv#contract-version: }; case "$cvn" in ''|*[!0-9]*) cvn=0 ;; esac
[ "$cv" = "contract-version: $cvn" ] && [ "$cvn" -ge 58 ] && ok "docs/stackshot-contracts.md: contract-version $cvn (58 or higher)" || bad "version line: $cv"
grep -q '^- \*\*58\*\*' "$C" && grep -q '^| 38 | Agent state' "$C" && grep -q '^## 38\. Agent state' "$C" && ok "changelog line 58, the index row and the section 38 exist" || bad "contract entries"
sec=$(awk '/^## 38\. Agent state/{p=1; next} /^## /{p=0} p' "$C")
for need in 'agent-state.json' 'POST /client/agent-state' 'SALA_AGENT_STATE_POST_CMD' 'SALA_AGENT_STATE_TIMEOUT' 'SALA_STACKSHOT_CHECKOUT' '"schema"' 'running(' '15 minutes' 'unknown' '1 MB' 'unstable' 'tests/agentstate.sh'; do
    has "$sec" "$need" && ok "interface 38 names: $need" || bad "interface 38 does not name: $need"
done
for k in SALA_AGENT_STATE SALA_AGENT_STATE_POST_CMD SALA_AGENT_STATE_TIMEOUT SALA_STACKSHOT_CHECKOUT SALA_AGENT_STATE_TRANSCRIPTS; do
    grep -q "^#$k=" "$ROOT/config.example" && ok "config.example lists $k" || bad "config.example lacks $k"
done
grep -q 'agent-state.json' "$ROOT/lib/heartbeat.sh" && grep -q 'agent-state.json' "$ROOT/docs/heartbeat-store.md" && ok "the heartbeat header and docs/heartbeat-store.md name the file" || bad "docs"

echo "== PARITY with stackshot's own audit (the real checkout, when this machine has it)"
RPY="$REAL_SS/.venv/bin/python"
if [ -f "$REAL_SS/stackshot/audit/subagent_tie.py" ] && [ -x "$RPY" ]; then
    rm -rf "$LIVE" "$HOME/.claude/projects" "$SLP"; mkdir -p "$HOME/.claude/projects" "$SLP"; rm -f "$HOME"/.claude/sessions/*.json; release
    HOLD="$HOME/hold2"; mkfifo "$HOLD"; for _ in $(seq "$NHOLD"); do ( exec 3<>"$HOLD"; read -t 900 -u 3 _x ) & pids+=($!); done
    python3 "$HOME/mk.py" real "${pids[@]}"
    out=$(CK="$REAL_SS" hb); rc=$?
    [ "$rc" = 0 ] && [ -s "$AS" ] && ok "the heartbeat ran against the real checkout ($(JQ 'len(d["agents"])' < "$AS") agents from real transcript folders)" || bad "real run: rc=$rc $out"
    cat > "$HOME/parity.py" <<'PY'
import json, os, sys, time
os.environ["HOME"] = os.environ["HOME"]
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import importlib, types
from stackshot.service import audit_ticks as at, save_hooks, handoff_hooks
# the web server installs these at its import (web/wiring.py); only the two this read reaches are given: the audit's module loader and the session-id lookup (none needed here)
save_hooks._hooks_ = types.SimpleNamespace(audit_mod=lambda name: importlib.import_module("stackshot.audit." + name))
handoff_hooks._hooks_ = types.SimpleNamespace(session_id=lambda w: "")
now = time.time(); out = {}
for name in sys.argv[2:]:
    try:
        subs = at._mover_subagents(name, {}, now)
    except Exception as e:
        out[name] = "unknown:%s:%s" % (e.__class__.__name__, str(e)[:100])
    else:
        out[name] = sorted([s["id"], bool(s.get("quiet")), bool(s.get("unreadable"))] for s in subs)
print(json.dumps(out))
PY
    names=$(JQ 'sorted(d["agents"])' < "$AS" | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)))')
    # shellcheck disable=SC2086
    "$RPY" -B "$HOME/parity.py" "$REAL_SS" $names > "$HOME/parity.json" 2> "$HOME/parity.err"; prc=$?
    [ "$prc" = 0 ] && [ -s "$HOME/parity.json" ] && ok "stackshot's _mover_subagents answered for every agent" || bad "stackshot side: rc=$prc $(tail -3 "$HOME/parity.err")"
    r=$(python3 - "$AS" "$HOME/parity.json" <<'PY'
import json, sys
mine = json.load(open(sys.argv[1]))["agents"]; theirs = json.load(open(sys.argv[2]))
bad = []
for name, a in sorted(mine.items()):
    t = theirs.get(name)
    got = sorted([s["id"], bool(s.get("quiet")), bool(s.get("unreadable"))] for s in a["subagents"])
    if isinstance(t, str) or t is None:
        if a["state"] != "unknown": bad.append((name, "stackshot " + t + ", sala " + a["state"]))
        continue
    if got != t: bad.append((name, "subagents differ", got, t))
    busy = a["pane"] == "turn" or bool(t)
    if (a["state"] == "busy") != busy: bad.append((name, "state", a["state"], a["pane"], len(t)))
print(len(mine), "agents compared;", "DIVERGED " + json.dumps(bad) if bad else "same")
PY
)
    case "$r" in *" same") ok "sala's subagent list and busy/idle equal stackshot's audit for every agent: $r" ;; *) bad "parity: $r" ;; esac
    n=$(JQ 'sum(len(a["subagents"]) for a in d["agents"].values())' < "$AS"); [ "$n" -gt 5 ] && ok "(the fixtures were not trivial: $n subagents listed in all)" || bad "too few subagents listed: $n"
else
    echo "  skip parity: no stackshot checkout with a virtualenv at $REAL_SS (set SALA_PARITY_STACKSHOT); a machine with none skips it"
fi

[ "$fail" = 0 ] && echo "agentstate: pass" || echo "agentstate: FAIL"
exit $fail
