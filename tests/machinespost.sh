#!/usr/bin/env bash
# tests/machinespost.sh — the machine list the heartbeat writes and hands to stackshot (lib/machinespost.py, lib/heartbeat.sh "machines.json", docs/stackshot-contracts.md interface 39).
# The heartbeat writes <live store>/<letter>/machines.json (sala's machine list, `machine_list()` in lib/machines.py, and the machine files named and not read) beside agent-state.json, and
# hands it to stackshot with SALA_MACHINES_POST_CMD when the list changed since the last good post, else every 10 minutes. A made-up fleet folder and a stub post command play the owner's
# files and the server; no real machine, no tmux, no claude, no network. What is checked:
#  - the body: schema 1, `written` a whole epoch second, `machines` equal to what `sala machines --json` prints for the same files (the one reader), every entry with exactly machines.KEYS in
#    their order, `not_read` the files named and not read; the file is atomic (no temp file left), rewritten on every run, never in the store repo's commit;
#  - the post: the file's path is the command's last argument and the posted bytes are the file; an unchanged list is not posted again inside 10 minutes and is after them (with a minute's
#    slack); a changed list is posted at once; a failed post is tried again on the next run; the default command is the stackshot client's `post machines --file`, with no pass;
#  - a failing, 404, not-ok, missing or slow command logs ONE line per five minutes to salamander-machines.log and never fails the heartbeat; a slow one is stopped after the timeout;
#  - SALA_MACHINES_POST=off, an empty command, --no-push and --dry-run (counts only, nothing written); a list with no machine in it is neither written nor posted (the last good file stays);
#    no machine file named is silent; a body over the limit is written and not posted; no secret reaches the file, the log or the command line;
#  - the readings on each row (version 62): online and last_seen from a `tailscale` stand-in first on the PATH (an online peer, an offline one with its last seen time, a node found by the first
#    label of its DNS name, a stale duplicate node, a row no node matches), the posting box's own row (true, with versions claude and sala; every other row {}), `checked` the second of `written`,
#    a failing, garbled, missing or hanging tailscale leaving online and last_seen null with the post still going, the fingerprint blind to `checked` alone, the 16-entry cap, and the body against
#    the contract's own sample;
#  - the contract text and the settings in config.example.
# SAFETY: HOME and every file are in a mktemp -d (prefix s2machines-) held with flock and removed on exit, pass or fail; no tmux, no claude, no network; the processes the suite starts that
# can outlive a command are the stubs' `sleep` (the post's, and the tailscale stand-in's), which the post's own timeout and the reading's stop by their process group; nothing is killed by name; no git user key is set (identity through the environment, in the sandbox repo only).
# Usage: bash tests/machinespost.sh   (exit 0 = pass; some 30 s)
set -u
unset TMUX TMUX_PANE XDG_STATE_HOME SALA_MASTER SALA_SLEEP_DIR SALA_FLEET_HOSTS SALA_SESSIONS_FILE SALA_SIDECAR SALA_STATE_DIR SALA_SESSION_URL SALA_AGENT_STATE SALA_AGENT_STATE_POST_CMD \
      SALA_MACHINES_POST SALA_MACHINES_POST_CMD SALA_MACHINES_POST_TIMEOUT SALA_MACHINES_POST_MAX_BODY SALA_STACKSHOT_CHECKOUT SALA_STACKSHOT_CLIENT SALA_STACKSHOT_DIR SALA_FLEET_NAMES \
      SALA_MACHINE_FOLLOW_MACHINES MACHINE_HOLDS_TOML MACHINE_HOLDS_CANDIDATES MACHINE_HOLDS_HUB TNR_CONF SALA_HEARTBEAT_STATE_DIR SALA_HEARTBEAT_REPO SALA_HEARTBEAT_DIR STACKSHOT_CLIENT_PASS
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
T=""
cleanup() { [ -z "$T" ] || { exec 8<&-; rm -rf "$T" 2>/dev/null; }; true; }; trap cleanup EXIT   # set before the folder exists
T=$(mktemp -d "${TMPDIR:-/tmp}/s2machines-XXXXXX")
exec 8< "$T"; flock -n 8 2>/dev/null   # systemd-tmpfiles' ageing skips a directory held with flock
case "$T" in /tmp/*|"${TMPDIR:-/tmp}"/*) ;; *) echo "machinespost: the temporary folder is not under the temporary directory ($T) - refusing to run"; exit 1 ;; esac
export HOME=$T/home SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC XDG_RUNTIME_DIR=$T/run TMUX_TMPDIR=$T/tmux SALA_AUTO_UPDATE=off PYTHONDONTWRITEBYTECODE=1 SALA_STACKSHOT_PASS=off
mkdir -p "$HOME/.claude/sessions" "$XDG_RUNTIME_DIR" "$TMUX_TMPDIR"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT"
SALA="$ROOT/bin/salamander"
# ---- a `tailscale` stand-in first on the PATH, so no run reads this machine's real tailnet: `tailscale status --json` prints $HOME/ts.json, or, by $HOME/ts.mode, fails, prints junk or hangs
mkdir -p "$T/shim"
cat > "$T/shim/tailscale" <<'SH'
#!/bin/bash
echo "$*" >> "$HOME/ts.calls"
[ "$*" = "status --json" ] || exit 2
case "$(cat "$HOME/ts.mode" 2>/dev/null || echo ok)" in
    ok) cat "$HOME/ts.json" ;;
    fail) echo "failed to connect to local tailscaled" >&2; exit 1 ;;
    junk) echo "this is not json" ;;
    hang) echo $$ > "$HOME/ts.pid"; exec sleep 60 ;;
esac
SH
chmod +x "$T/shim/tailscale"
export PATH="$T/shim:$PATH"
python3 - "$HOME/ts.json" <<'PY'
import json, sys
node = lambda host, dns, online, seen: {"HostName": host, "DNSName": dns, "Online": online, "LastSeen": seen}
doc = {"Version": "1.0", "Self": node("SBOX-OS", "sbox-os.example.invalid.", True, "2026-11-25T02:00:00Z"),
       "Peer": {"nodekey:a1": node("Example-Alpha", "example-alpha.example.invalid.", True, "2026-11-25T01:30:00Z"),
                "nodekey:a0": node("example-alpha", "example-alpha-1.example.invalid.", False, "2026-11-20T01:00:00Z"),   # an old node of the same machine: the online one wins
                "nodekey:b1": node("beta-os", "beta-os.example.invalid.", False, "2026-11-25T01:00:00.123456789Z"),
                "nodekey:e1": node("localhost", "Example-Eps.example.invalid.", False, "0001-01-01T00:00:00Z"),               # found by the first label of its DNS name; never seen
                "nodekey:z1": node("unrelated-box", "unrelated-box.example.invalid.", True, "2026-11-25T01:59:00Z")}}
json.dump(doc, open(sys.argv[1], "w"))
PY
echo ok > "$HOME/ts.mode"; : > "$HOME/ts.calls"
JQ() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(eval(sys.argv[1]), sort_keys=True))' "$1"; }   # JQ <python expr over d> < json

# ---- a made-up fleet folder (the owner's machine files) --------------------------------------------------------------------------------------------
D=$T/data; mkdir -p "$D/claude/tailnet-route" "$D/ssh" "$D/claude/host-move" "$D/claude/machine-follow"
printf '%s\t%s\t%s\n' '# os hostname' 'fleet name' 'board letter' > "$D/fleet-names.tsv"
printf '%s\t%s\t%s\n' alpha-os example-alpha a beta-os example-beta b GAMMA-OS example-gamma c >> "$D/fleet-names.tsv"
echo '# d = example-delta, retired (gone for good): the letter stays reserved' >> "$D/fleet-names.tsv"
cat > "$D/claude/tailnet-route/candidates.conf" <<'EOF'
host example-alpha 192.0.2.1 2001:db8::1
host example-eps 192.0.2.5 2001:db8::5
host Gamma-OS 192.0.2.3 2001:db8::3
EOF
cat > "$D/ssh/fleet.conf" <<'EOF'
Host example-alpha
  HostName alpha.example.invalid
Host example-beta example-eta
  HostName beta.example.invalid
Host *
  User nobody
EOF
cat > "$D/claude/host-move/machine-holds.toml" <<'EOF'
[[hosts]]
role = "sala-host"
host = "example-alpha"
name = "sala.example.invalid"
EOF
# no machine-follow/machines.toml on purpose: it is named, and `not_read` says so
FOLLOW=$D/claude/machine-follow/machines.toml
NAMES=$D/fleet-names.tsv

# ---- the stub post command ----------------------------------------------------------------------------------------------------------------------
cat > "$HOME/push.sh" <<'SH'
#!/bin/bash
# the stub of the post command: the file's path is its last argument; its mode is in push.mode
echo "$#:${*: -1}" >> "$HOME/push.calls"
case "$(cat "$HOME/push.mode" 2>/dev/null || echo ok)" in
    ok) cp "${@: -1}" "$HOME/pushed.json"; echo '{"ok":true,"machines":4}' ;;
    fail) echo "[404] not found" >&2; exit 1 ;;
    notok) echo '{"ok":false,"error":"schema"}'; exit 0 ;;
    slow) echo $$ > "$HOME/push.pid"; exec sleep 60 ;;
esac
SH
chmod +x "$HOME/push.sh"
: > "$HOME/push.calls"; echo ok > "$HOME/push.mode"

LIVE="$HOME/hb"; MJ="$LIVE/q/machines.json"; LOGD="$HOME/.claude"; MLOG="$LOGD/salamander-machines.log"; STAMP="$LOGD/salamander-machines-post.json"
hb() {   # hb [heartbeat args] → output; PUSHCMD overrides the post command (an empty PUSHCMD = no post); NAMESV overrides the names file; HBENV adds settings
    env SALA_HEARTBEAT_STATE_DIR="$LIVE" SALA_HEARTBEAT_GIT=off SALA_HEARTBEAT_LETTER=q SALA_HEARTBEAT_NAME=sbox SALA_SESSIONS=write SALA_AGENT_STATE=off \
        SALA_FLEET_NAMES="${NAMESV-$NAMES}" SALA_MACHINE_FOLLOW_MACHINES="$FOLLOW" SALA_MACHINES_POST_CMD="${PUSHCMD-$HOME/push.sh}" ${HBENV:-} "$SALA" heartbeat "$@" 2>&1
}
calls() { wc -l < "$HOME/push.calls"; }
logn() { [ -f "$MLOG" ] && wc -l < "$MLOG" || echo 0; }
age_stamp() { python3 - "$STAMP" "$1" <<'PY'
import json, sys, time
d = json.load(open(sys.argv[1])); d["at"] = int(time.time()) - int(sys.argv[2]); json.dump(d, open(sys.argv[1], "w"))
PY
}
reset_log() { : > "$MLOG"; rm -f "$LOGD"/salamander-machines.*.mark; }

echo "== the body: the machine list, as the one reader gives it"
out=$(hb); rc=$?
[ "$rc" = 0 ] && [ -s "$MJ" ] && ok "the heartbeat wrote machines.json" || bad "heartbeat rc=$rc: $out"
r=$(JQ '[sorted(d), d["schema"], type(d["written"]).__name__, abs(d["written"] - __import__("time").time()) < 120]' < "$MJ")
[ "$r" = '[["machines", "not_read", "schema", "written"], 1, "int", true]' ] && ok "the keys are schema, written (a whole epoch second), machines and not_read" || bad "head: $r"
env SALA_FLEET_NAMES="$NAMES" SALA_MACHINE_FOLLOW_MACHINES="$FOLLOW" "$SALA" machines --json > "$HOME/cli.json" 2>/dev/null
r=$(python3 - "$MJ" "$HOME/cli.json" "$ROOT/lib" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[3]); import machines
f, c = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
strip = lambda ms: [{k: v for k, v in m.items() if k != "checked"} for m in ms]   # `checked` is the second each list was read: the two runs may be a second apart
print(strip(f["machines"]) == strip(c["machines"]), f["not_read"] == c["not_read"], len(f["machines"]) >= 5,
      all(list(m) == list(machines.KEYS) + list(machines.READING_KEYS) for m in f["machines"] + c["machines"]),
      list(machines.KEYS) == ["name", "hostname", "letter", "ssh", "addresses", "roles", "retired", "sources"], list(machines.READING_KEYS) == ["online", "last_seen", "versions", "checked"])
PY
)
[ "$r" = "True True True True True True" ] && ok "machines equal what \`sala machines --json\` prints for the same files (but for the second each was read), every entry has machines.KEYS then READING_KEYS in order (the one place)" || bad "parity: $r"
r=$(JQ '[d["not_read"], [m["name"] for m in d["machines"]][:4], [m["retired"] for m in d["machines"] if m["name"] == "example-delta"], [m["roles"] for m in d["machines"] if m["name"] == "example-alpha"]]' < "$MJ")
[ "$r" = '[["machines.toml"], ["example-alpha", "example-beta", "example-gamma", "example-delta"], [true], [["sala-host"]]]' ] && ok "not_read names the follow list that is not there; the names file's order, a retired machine, a host role" || bad "content: $r"
ls -a "$LIVE/q" | grep -q 'machines.json.*tmp' && bad "a temp file was left beside the file" || ok "no temp file left beside it (atomic write)"
[ "$(calls)" = 1 ] && same_file "$MJ" "$HOME/pushed.json" && ok "the post got the file's own bytes, once" || bad "calls=$(calls)"
[ "$(tail -1 "$HOME/push.calls" | cut -d: -f2-)" = "$MJ" ] && ok "the command's last argument is the file's path" || bad "push args: $(tail -1 "$HOME/push.calls")"
[ ! -e "$MLOG" ] && ok "a clean run logs nothing" || bad "log: $(cat "$MLOG")"
[ -s "$STAMP" ] && [ "$(JQ 'sorted(d)' < "$STAMP")" = '["at", "hash"]' ] && ok "the last good post is on record (hash and time, in the log folder, not the store)" || bad "stamp: $(cat "$STAMP" 2>/dev/null)"

echo "== when it is posted: changed at once, unchanged after 10 minutes"
cp "$MJ" "$HOME/m.1"; sleep 1.3; out=$(hb); rc=$?
w1=$(JQ 'd["written"]' < "$HOME/m.1"); w2=$(JQ 'd["written"]' < "$MJ")
[ "$rc" = 0 ] && [ "$w2" -gt "$w1" ] && ok "written moves on every run ($w1 -> $w2)" || bad "written: $w1 $w2 rc=$rc"
[ "$(calls)" = 1 ] && ok "the same list is not posted again at once (still 1 post)" || bad "reposted: $(calls)"
age_stamp 300; out=$(hb); [ "$(calls)" = 1 ] && ok "…nor 5 minutes after the post" || bad "after 300 s: $(calls)"
age_stamp 700; out=$(hb); [ "$(calls)" = 2 ] && ok "…but 700 s after the last post it is, so stackshot can show the list's age" || bad "after 700 s: $(calls)"
age_stamp 550; out=$(hb); [ "$(calls)" = 3 ] && ok "a run a few seconds early (550 s) still posts: a minute's slack, so a five-minute timer posts every second run" || bad "after 550 s: $(calls)"
age_stamp 520; out=$(hb); [ "$(calls)" = 3 ] && ok "…and 520 s does not" || bad "after 520 s: $(calls)"
printf 'Host example-theta\n  HostName theta.example.invalid\n' >> "$D/ssh/fleet.conf"
out=$(hb); rc=$?
[ "$rc" = 0 ] && [ "$(calls)" = 4 ] && has "$(cat "$HOME/pushed.json")" "example-theta" && ok "a changed list (a new ssh host) is posted at once, the stamp being young, and the post has it" || bad "changed: rc=$rc calls=$(calls)"
python3 - "$ROOT/lib" "$T" <<'PY' && ok "due(): another list, no record, a record in the future and a damaged record are posted; a young one is not" || bad "due() cases"
import sys, time
sys.path.insert(0, sys.argv[1]); import machinespost as mp
now = time.time(); s = {"hash": "h", "at": now - 100}
assert mp.due(s, "h", now) is False
assert mp.due(s, "other", now) is True
assert mp.due(None, "h", now) is True
assert mp.due({"hash": "h", "at": "x"}, "h", now) is True
assert mp.due({"hash": "h", "at": now + 500}, "h", now) is True
assert mp.due({"hash": "h", "at": now - 539}, "h", now) is False
assert mp.due({"hash": "h", "at": now - 541}, "h", now) is True
PY

echo "== --dry-run writes nothing and shows counts only; --no-push writes and posts nothing"
cp "$MJ" "$HOME/m.2"; n=$(calls); sleep 1.1
out=$(hb --dry-run)
same_file "$MJ" "$HOME/m.2" && has "$out" "== machines: " && has "$out" " machines (" && ! has "$out" "example-alpha" && ! has "$out" "192.0.2" && [ "$(calls)" = "$n" ] \
    && ok "dry run: the file is untouched, no post; one line of counts, no name or address in the output" || bad "dry: $out"
out=$(hb --no-push); [ "$(calls)" = "$n" ] && ! same_file "$MJ" "$HOME/m.2" && ok "--no-push rewrites the file (written moves) and posts nothing" || bad "no-push: calls $(calls) vs $n"

echo "== SALA_MACHINES_POST=off writes and posts nothing; an empty command posts nothing"
rm -f "$MJ"; n=$(calls)
out=$(HBENV="SALA_MACHINES_POST=off" hb); rc=$?
[ "$rc" = 0 ] && [ ! -e "$MJ" ] && [ "$(calls)" = "$n" ] && [ -s "$LIVE/q/sessions.json" ] && ok "off: no file, no post, the other files as before" || bad "off: rc=$rc"
out=$(PUSHCMD="" hb); rc=$?
[ "$rc" = 0 ] && [ -s "$MJ" ] && [ "$(calls)" = "$n" ] && ok "an empty SALA_MACHINES_POST_CMD: the file is written, nothing is posted" || bad "empty cmd: rc=$rc"

echo "== no machine file named: silent; named and none readable: nothing written, the last good file stays, one line"
cp "$MJ" "$HOME/m.3"; n=$(calls); reset_log; sleep 1.1
out=$(env SALA_HEARTBEAT_STATE_DIR="$LIVE" SALA_HEARTBEAT_GIT=off SALA_HEARTBEAT_LETTER=q SALA_HEARTBEAT_NAME=sbox SALA_SESSIONS=write SALA_AGENT_STATE=off SALA_MACHINES_POST_CMD="$HOME/push.sh" "$SALA" heartbeat 2>&1); rc=$?
[ "$rc" = 0 ] && same_file "$MJ" "$HOME/m.3" && [ "$(calls)" = "$n" ] && [ "$(logn)" = 0 ] && ok "no SALA_FLEET_NAMES and no follow list: no write, no post, no log line, heartbeat 0" || bad "none named: rc=$rc log=$(logn)"
NONE=$T/none/fleet-names.tsv
out=$(NAMESV="$NONE" hb); rc=$?
[ "$rc" = 0 ] && same_file "$MJ" "$HOME/m.3" && [ "$(calls)" = "$n" ] && ok "named but nothing readable: the file is byte for byte the last good one, no post, heartbeat 0" || bad "unreadable: rc=$rc"
[ "$(logn)" = 1 ] && has "$(cat "$MLOG")" "no machine could be read" && has "$(cat "$MLOG")" "last good file stays" && ok "one line says so" || bad "log: $(cat "$MLOG" 2>/dev/null)"
out=$(NAMESV="$NONE" hb --dry-run); has "$out" "no machine could be read" && ok "a dry run says so too" || bad "dry empty: $out"

echo "== the post: a failure logs once per five minutes and never fails the heartbeat; it is tried again"
reset_log; echo fail > "$HOME/push.mode"; rm -f "$STAMP"; n=$(calls)
out=$(hb); rc=$?
[ "$rc" = 0 ] && [ "$(logn)" = 1 ] && has "$(cat "$MLOG")" "exited 1" && has "$(cat "$MLOG")" "404" && ok "a command that exits 1 with a 404: the heartbeat exits 0, one line (with the command's own words)" || bad "fail: rc=$rc log=$(cat "$MLOG")"
[ ! -e "$STAMP" ] && ok "a failed post leaves no record, so it is not taken for done" || bad "stamp after failure"
out=$(hb); [ "$(logn)" = 1 ] && [ "$(calls)" = $((n + 2)) ] && ok "the next run tries again (2 attempts) and logs nothing inside five minutes" || bad "second: log=$(logn) calls=$(calls) n=$n"
grep -q ' machines: ' "$MLOG" && ok "the line is tagged machines, in salamander-machines.log (not the agent-state log)" || bad "tag: $(cat "$MLOG")"
touch -d '10 minutes ago' "$LOGD"/salamander-machines.post.mark; out=$(hb)
[ "$(logn)" = 2 ] && ok "five minutes later it logs again" || bad "third: $(logn)"
echo notok > "$HOME/push.mode"; touch -d '10 minutes ago' "$LOGD"/salamander-machines.post.mark; out=$(hb); rc=$?
[ "$rc" = 0 ] && [ "$(logn)" = 3 ] && has "$(tail -1 "$MLOG")" "answer was not ok" && ok "an answer that is JSON with ok not true is a failure, logged" || bad "notok: rc=$rc $(tail -1 "$MLOG")"
echo ok > "$HOME/push.mode"; touch -d '10 minutes ago' "$LOGD"/salamander-machines.post.mark; out=$(hb)
[ "$(logn)" = 3 ] && [ -s "$STAMP" ] && ok "a good answer ({ok: true}) logs nothing and the post is on record again" || bad "good: $(logn)"
rm -f "$STAMP"; out=$(PUSHCMD="$HOME/no-such-command" hb); rc=$?
touch -d '10 minutes ago' "$LOGD"/salamander-machines.post.mark; out=$(PUSHCMD="$HOME/no-such-command" hb); rc2=$?
[ "$rc" = 0 ] && [ "$rc2" = 0 ] && has "$(tail -1 "$MLOG")" "cannot start" && ok "a command that does not exist: logged, heartbeat exits 0" || bad "missing: $rc $rc2 $(tail -1 "$MLOG")"

echo "== the post: a slow command is stopped after SALA_MACHINES_POST_TIMEOUT, process group and all"
reset_log; echo slow > "$HOME/push.mode"; rm -f "$HOME/push.pid" "$STAMP"
t0=$SECONDS; out=$(HBENV="SALA_MACHINES_POST_TIMEOUT=2" hb); rc=$?; dt=$((SECONDS - t0))
[ "$rc" = 0 ] && [ "$dt" -lt 40 ] && ok "the heartbeat returned (rc 0) after ${dt}s, the command's 60 s cut at 2" || bad "slow: rc=$rc dt=$dt"
has "$(cat "$MLOG")" "longer than 2" && ok "one line names the timeout" || bad "timeout log: $(cat "$MLOG")"
sp=$(cat "$HOME/push.pid" 2>/dev/null || echo 0)
[ "$sp" -gt 1 ] && ! kill -0 "$sp" 2>/dev/null && ok "the command's process is gone (its group was stopped)" || bad "the slow command (pid $sp) is still running"
echo ok > "$HOME/push.mode"

echo "== a body over the limit is written and not posted; any other trouble never fails the heartbeat"
reset_log; rm -f "$STAMP"; n=$(calls)
out=$(HBENV="SALA_MACHINES_POST_MAX_BODY=100" hb); rc=$?
[ "$rc" = 0 ] && [ "$(calls)" = "$n" ] && [ -s "$MJ" ] && [ "$(logn)" = 1 ] && has "$(cat "$MLOG")" "over the 100-byte limit" && ok "over SALA_MACHINES_POST_MAX_BODY: file written, no post, one line" || bad "big: rc=$rc calls=$(calls) log=$(cat "$MLOG")"
python3 - "$ROOT/lib" <<'PY' && ok "publish() with a junk environment returns \"\" and raises nothing" || bad "publish raised"
import sys
sys.path.insert(0, sys.argv[1]); import machinespost as mp
assert mp.publish({}, "q", "run") == ""
assert mp.publish({"HB_STATE": "/nonexistent/x", "HB_MP_NAMES": "/nonexistent/names", "HB_MP_LOGDIR": "/nonexistent/log", "HB_MP_MAX_BODY": "abc", "HB_MP_TIMEOUT": "x"}, "q", "run") == ""
assert mp.publish({"HB_STATE": 5, "HB_MP_NAMES": 7}, "q", "run") == ""
PY

echo "== the default post command is the stackshot client's \`post machines --file <path>\`, with no pass"
cat > "$HOME/client.py" <<'PY'
import json, os, sys
open(os.environ["HOME"] + "/client.argv", "w").write(json.dumps(sys.argv[1:]))
open(os.environ["HOME"] + "/client.pass", "w").write("set" if "STACKSHOT_CLIENT_PASS" in os.environ else "unset")
print('{"ok":true,"machines":4}')
PY
rm -f "$STAMP"
out=$(env -u SALA_MACHINES_POST_CMD STACKSHOT_CLIENT_PASS=not-a-real-pass-s2m SALA_HEARTBEAT_STATE_DIR="$LIVE" SALA_HEARTBEAT_GIT=off SALA_HEARTBEAT_LETTER=q SALA_HEARTBEAT_NAME=sbox SALA_SESSIONS=write SALA_AGENT_STATE=off \
    SALA_FLEET_NAMES="$NAMES" SALA_MACHINE_FOLLOW_MACHINES="$FOLLOW" SALA_STACKSHOT_CLIENT="$HOME/client.py" "$SALA" heartbeat 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(cat "$HOME/client.argv" 2>/dev/null)" = "[\"post\", \"machines\", \"--file\", \"$MJ\"]" ] && ok "the client got: post machines --file <the file>" || bad "default cmd: rc=$rc argv=$(cat "$HOME/client.argv" 2>/dev/null) $out"
[ "$(cat "$HOME/client.pass" 2>/dev/null)" = unset ] && ok "STACKSHOT_CLIENT_PASS was unset for the client, though the heartbeat had one" || bad "the client saw a pass: $(cat "$HOME/client.pass" 2>/dev/null)"
dline=$(grep -F 'SALA_MACHINES_POST_CMD="${_mp_client' "$ROOT/lib/heartbeat.sh")
dcode=${dline%%\"   \#*}
[ -n "$dline" ] && ! grep -q 'SALA_FORM_PY\|stackshot_form' <<<"$dcode" && grep -q 'env -u STACKSHOT_CLIENT_PASS python3' <<<"$dcode" && ok "the default command is the bare client under env -u STACKSHOT_CLIENT_PASS, no form wrapper" || bad "default command line: $dline"
rm -f "$HOME/client.argv" "$HOME/client.pass"
out=$(env -u SALA_MACHINES_POST_CMD SALA_HEARTBEAT_STATE_DIR="$LIVE" SALA_HEARTBEAT_GIT=off SALA_HEARTBEAT_LETTER=q SALA_HEARTBEAT_NAME=sbox SALA_SESSIONS=write SALA_AGENT_STATE=off \
    SALA_FLEET_NAMES="$NAMES" SALA_MACHINE_FOLLOW_MACHINES="$FOLLOW" SALA_STACKSHOT_CLIENT="$HOME/none.py" "$SALA" heartbeat 2>&1); rc=$?
[ "$rc" = 0 ] && [ -s "$MJ" ] && [ ! -e "$HOME/client.argv" ] && ok "no stackshot client on the box: the file is written, no post, no failure" || bad "no client: rc=$rc"

echo "== no secret reaches the file, the log or the command line"
reset_log; echo fail > "$HOME/push.mode"; rm -f "$STAMP"
out=$(STACKSHOT_CLIENT_PASS=not-a-real-pass-s2m HBENV="STACKSHOT_CLIENT_PASS=not-a-real-pass-s2m" hb); rc=$?
leak=0; for f in "$MJ" "$MLOG" "$STAMP" "$HOME/push.calls"; do [ -f "$f" ] && grep -q 'not-a-real-pass-s2m' "$f" && leak=1; done
[ "$rc" = 0 ] && [ "$leak" = 0 ] && ok "a pass in the heartbeat's environment is in none of machines.json, the log, the post record or the post command's arguments" || bad "leak=$leak rc=$rc"
echo ok > "$HOME/push.mode"

echo "== the file is never in the store repo's commit"
STORE="$HOME/store"; git init -q "$STORE" 2>/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
rm -rf "$LIVE"
out=$(env SALA_HEARTBEAT_STATE_DIR="$LIVE" SALA_HEARTBEAT_GIT=full SALA_HEARTBEAT_REPO="$STORE" SALA_HEARTBEAT_DIR=board SALA_HEARTBEAT_LETTER=q SALA_HEARTBEAT_NAME=sbox SALA_SESSIONS=write SALA_AGENT_STATE=off \
    SALA_FLEET_NAMES="$NAMES" SALA_MACHINE_FOLLOW_MACHINES="$FOLLOW" SALA_MACHINES_POST_CMD="$HOME/push.sh" "$SALA" heartbeat --no-push 2>&1); rc=$?
files=$(git -C "$STORE" ls-files | tr '\n' ' '); lastc=$(git -C "$STORE" show --stat --format=%s HEAD 2>/dev/null | tr '\n' ' ')
[ "$rc" = 0 ] && [ -s "$MJ" ] && ok "git mode full: machines.json is in the live store" || bad "git mode: rc=$rc"
has "$files" "board/q/sessions.json" && ! has "$files$lastc" "machines.json" && ok "the commit holds the store's files and not machines.json (tracked: $files)" || bad "tracked: $files / $lastc"
[ -z "$(git -C "$STORE" status --porcelain | grep machines.json)" ] && ok "and the repo has no untracked machines.json" || bad "untracked in the repo"
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

echo "== interface 38 still works with the shared post code (agentstate.post and note keep their old shape)"
python3 - "$ROOT/lib" "$HOME" <<'PY' && ok "agentstate.post: True for a clean answer, False for no command, a failing one and a missing one; its log is still salamander-agent-state.log, tagged agent-state" || bad "agentstate shape"
import os, sys, tempfile
sys.path.insert(0, sys.argv[1]); import agentstate as a
d = tempfile.mkdtemp(prefix="s2machines-ag-", dir=sys.argv[2])
open(d + "/ok.sh", "w").write("#!/bin/sh\necho '{\"ok\":true}'\n"); os.chmod(d + "/ok.sh", 0o755)
open(d + "/no.sh", "w").write("#!/bin/sh\nexit 3\n"); os.chmod(d + "/no.sh", 0o755)
assert a.post(d + "/ok.sh", "/x", 5, d) is True
assert a.post("", "/x", 5, d) is False
assert a.post(d + "/no.sh", "/x", 5, d) is False
assert a.post(d + "/missing", "/x", 5, d) is False
log = open(d + "/" + a.LOG_NAME).read()
assert "agent-state: not handed to stackshot" in log and os.path.exists(d + "/salamander-agent-state.post.mark"), log
PY

echo "== the readings: online and last_seen from the tailnet, versions of this box only, checked"
mkdir -p "$T/mini"; for t in bash sh cat cp sleep env git; do p=$(command -v "$t") && ln -sf "$p" "$T/mini/$t"; done   # a PATH with the tools the stubs need and no tailscale
PYX=$(command -v python3)
E1=$(python3 -c 'import calendar; print(calendar.timegm((2026, 11, 25, 1, 0, 0)))')
reset_log; echo ok > "$HOME/ts.mode"; rm -f "$STAMP"; : > "$HOME/ts.calls"; n=$(calls)
out=$(hb); rc=$?
r=$(JQ '[[m["online"], m["last_seen"], m["versions"]] for m in sorted(d["machines"], key=lambda m: m["name"]) if m["name"] in ("example-alpha", "example-beta", "example-gamma", "example-delta", "example-eps", "example-theta")]' < "$MJ")
[ "$rc" = 0 ] && [ "$r" = "[[true, null, {}], [false, $E1, {}], [null, null, {}], [false, null, {}], [null, null, {}], [null, null, {}]]" ] \
    && ok "an online peer (the online node of a machine registered twice wins; its last_seen null), an offline one with its last seen time (a fractional RFC 3339 time), one found by its DNS label and never seen (null), rows no node matches (null)" || bad "readings: rc=$rc $r"
r=$(JQ '[d["machines"][0]["name"], all(m["checked"] == d["written"] and type(m["checked"]).__name__ == "int" for m in d["machines"]), all(m["versions"] == {} for m in d["machines"])]' < "$MJ")
[ "$r" = '["example-alpha", true, true]' ] && ok "checked is the second of written on every row; no row of this fleet is the posting box, so every versions is {} (sala read nothing)" || bad "checked/versions: $r"
[ "$(sort -u "$HOME/ts.calls")" = "status --json" ] && [ "$(wc -l < "$HOME/ts.calls")" = 1 ] && ok "tailscale was asked once per run, for \`status --json\` and nothing else (no ssh, no other call)" || bad "tailscale calls: $(cat "$HOME/ts.calls")"
[ "$(calls)" = $((n + 1)) ] && [ "$(logn)" = 0 ] && ok "the list with its readings was posted, no log line" || bad "post: calls $(calls) n=$n log=$(logn)"
# the posting box's own row: the fleet names the heartbeat's own name (sbox) as a row of its own
D2=$T/data2; mkdir -p "$D2"
printf '%s\t%s\t%s\n' sbox-os sbox q alpha-os example-alpha a > "$D2/fleet-names.tsv"
printf '#!/bin/sh\necho "2.1.332 (Claude Code)"\n' > "$HOME/claude-stub"; chmod +x "$HOME/claude-stub"
rm -f "$STAMP"; out=$(NAMESV="$D2/fleet-names.tsv" HBENV="SALA_CLAUDE=$HOME/claude-stub" hb); rc=$?
SALA_SHA=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || true)
r=$(python3 - "$MJ" "$SALA_SHA" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); sha = sys.argv[2]
rows = {m["name"]: m for m in d["machines"]}
want = {"claude": "2.1.332"}
if sha: want["sala"] = sha
print(rows["sbox"]["online"] is True, rows["sbox"]["last_seen"] is None, rows["sbox"]["versions"] == want, rows["example-alpha"]["versions"] == {}, rows["example-alpha"]["online"] is True)
PY
)
[ "$rc" = 0 ] && [ "$r" = "True True True True True" ] && ok "the posting box's own row is online true (last_seen null) with versions claude (the heartbeat's cver) and sala (the checkout's short commit${SALA_SHA:+ $SALA_SHA}), the other row {}" || bad "own row: rc=$rc $r"
# tailscale failing or printing junk: every online and last_seen null, the post still goes, nothing is logged
for mode in fail junk; do
    echo $mode > "$HOME/ts.mode"; reset_log; rm -f "$STAMP"; n=$(calls)
    out=$(hb); rc=$?
    r=$(JQ 'sorted(set((m["online"], m["last_seen"]) for m in d["machines"]), key=str)' < "$MJ")
    [ "$rc" = 0 ] && [ "$r" = "[[null, null]]" ] && [ "$(calls)" = $((n + 1)) ] && [ "$(logn)" = 0 ] && ok "tailscale $mode: every online and last_seen null, the heartbeat exits 0 and the post goes" || bad "tailscale $mode: rc=$rc $r calls=$(calls) n=$n log=$(logn)"
done
echo hang > "$HOME/ts.mode"; reset_log; rm -f "$STAMP" "$HOME/ts.pid"; n=$(calls)
t0=$SECONDS; out=$(hb); rc=$?; dt=$((SECONDS - t0))
r=$(JQ 'sorted(set((m["online"], m["last_seen"]) for m in d["machines"]), key=str)' < "$MJ")
[ "$rc" = 0 ] && [ "$r" = "[[null, null]]" ] && [ "$(calls)" = $((n + 1)) ] && [ "$dt" -lt 50 ] && ok "a tailscale that hangs is stopped after 10 s (the run took ${dt}s): nulls, exit 0, the post goes" || bad "tailscale hang: rc=$rc $r calls=$(calls) dt=$dt"
tp=$(cat "$HOME/ts.pid" 2>/dev/null || echo 0)
[ "$tp" -gt 1 ] && ! kill -0 "$tp" 2>/dev/null && ok "the hung tailscale's process is gone (its group was stopped)" || bad "the hung tailscale (pid $tp) is still running"
echo ok > "$HOME/ts.mode"
# no tailscale on the PATH at all (a PATH of the stubs' tools alone): the same nulls, and publish() still posts
rm -rf "$T/st2" "$T/log2"; mkdir -p "$T/st2/q" "$T/log2"; n=$(calls)
r=$(env PATH="$T/mini" "$PYX" - "$ROOT/lib" "$D" "$T" "$HOME/push.sh" <<'PY'
import json, shutil, sys
sys.path.insert(0, sys.argv[1]); import machines as mc, machinespost as mp
D, T = sys.argv[2], sys.argv[3]
assert shutil.which("tailscale") is None
ms, _ = mc.read_with_readings(D + "/fleet-names.tsv", None, claude="1.2.3")
E = {"HB_STATE": T + "/st2", "HB_MP_NAMES": D + "/fleet-names.tsv", "HB_MP_CMD": sys.argv[4], "HB_MP_LOGDIR": T + "/log2", "HB_NAME": "sbox", "HB_CVER": "1.2.3"}
mp.publish(E, "q", "run")
body = json.load(open(T + "/st2/q/machines.json"))
print(len(ms) >= 5, {(m["online"], m["last_seen"]) for m in ms} == {(None, None)}, {(m["online"], m["last_seen"]) for m in body["machines"]} == {(None, None)}, len(body["machines"]) == len(ms))
PY
)
[ "$r" = "True True True True" ] && [ "$(calls)" = $((n + 1)) ] && ok "no tailscale on the PATH: online and last_seen null on every row, machines.json written and posted all the same" || bad "no tailscale: $r calls=$(calls) n=$n"
# the fingerprint (what decides a repost) leaves `checked` out, and nothing else
python3 - "$ROOT/lib" <<'PY' && ok "fingerprint(): the same list read a few minutes later (checked, written) is the same; another online, last_seen, versions or name, a row more, or another not_read, is another" || bad "fingerprint cases"
import copy, sys
sys.path.insert(0, sys.argv[1]); import machinespost as mp
row = {"name": "a", "hostname": "a-os", "letter": "a", "ssh": "a", "addresses": [], "roles": [], "retired": False, "sources": ["fleet-names.tsv"], "online": True, "last_seen": None, "versions": {"claude": "2"}, "checked": 1000}
doc = mp.build([row], [], 1000)
later = copy.deepcopy(doc); later["written"] = 1300; later["machines"][0]["checked"] = 1300
assert mp.fingerprint(doc) == mp.fingerprint(later)
for key, val in (("online", False), ("last_seen", 5), ("versions", {"claude": "3"}), ("name", "b")):
    other = copy.deepcopy(doc); other["machines"][0][key] = val
    assert mp.fingerprint(doc) != mp.fingerprint(other), key
more = copy.deepcopy(doc); more["machines"].append(dict(row, name="c"))
assert mp.fingerprint(doc) != mp.fingerprint(more)
assert mp.fingerprint(doc) != mp.fingerprint(mp.build([row], ["machines.toml"], 1000))
PY
# the body against the contract's own sample
rm -f "$STAMP"; out=$(hb)
python3 - "$ROOT/docs/stackshot-contracts.md" "$ROOT/lib" "$MJ" <<'PY' && ok "the contract's sample and the real body have the same shape: machines.KEYS then READING_KEYS, online true/false/null, last_seen a whole second or null, versions text to text (16 at most), checked a whole second" || bad "sample shape"
import json, re, sys
sys.path.insert(0, sys.argv[2]); import machines as mc
sec = open(sys.argv[1], encoding="utf-8").read().split("## 39. Machines")[1].split("\n## ")[0]
sample = json.loads(re.search(r"A sample: `(.*)`$", sec, re.M).group(1))
body = json.load(open(sys.argv[3]))
def row_ok(m):
    assert list(m) == list(mc.KEYS) + list(mc.READING_KEYS), list(m)
    assert isinstance(m["online"], (bool, type(None)))
    assert m["last_seen"] is None or (type(m["last_seen"]) is int and m["last_seen"] > 0)
    assert isinstance(m["versions"], dict) and len(m["versions"]) <= 16 and all(isinstance(k, str) and isinstance(v, str) for k, v in m["versions"].items())
    assert type(m["checked"]) is int and m["checked"] > 0
for doc in (sample, body):
    assert doc["schema"] == 1 and sorted(doc) == ["machines", "not_read", "schema", "written"] and isinstance(doc["not_read"], list)
    for m in doc["machines"]:
        row_ok(m)
assert {m["online"] for m in sample["machines"]} == {True, False, None}
assert any(m["versions"] for m in sample["machines"]) and any(m["last_seen"] for m in sample["machines"] if m["online"] is False)
assert all(m["last_seen"] is None for m in sample["machines"] if m["online"] is not False)
PY

echo "== the contract text and the settings"
C="$ROOT/docs/stackshot-contracts.md"
cv=$(sed -n 3p "$C"); cvn=${cv#contract-version: }; case "$cvn" in ''|*[!0-9]*) cvn=0 ;; esac
[ "$cv" = "contract-version: $cvn" ] && [ "$cvn" -ge 62 ] && ok "docs/stackshot-contracts.md: contract-version $cvn (62 or higher)" || bad "version line: $cv"
grep -q '^- \*\*60\*\*' "$C" && grep -q '^- \*\*62\*\*' "$C" && grep -q '^| 39 | Machines' "$C" && grep -q '^## 39\. Machines' "$C" && ok "changelog lines 60 and 62, the index row and the section 39 exist" || bad "contract entries"
sec=$(awk '/^## 39\. Machines/{p=1; next} /^## /{p=0} p' "$C")
for need in 'machines.json' 'POST /client/machines' 'SALA_MACHINES_POST_CMD' 'SALA_MACHINES_POST_TIMEOUT' 'SALA_MACHINES_POST_MAX_BODY' '"schema"' 'not_read' 'machine_list()' '10 minutes' '1 MB' '404' 'unstable' 'tests/machinespost.sh' 'stackshot'"'"'s to build' \
            '`online`' '`last_seen`' '`versions`' '`checked`' 'tailscale status --json' 'at most 16 entries' 'Absent or null means unknown' 'An empty `versions` means sala read nothing' 'older than the post' '900 s'; do
    has "$sec" "$need" && ok "interface 39 names: $need" || bad "interface 39 does not name: $need"
done
for k in SALA_MACHINES_POST SALA_MACHINES_POST_CMD SALA_MACHINES_POST_TIMEOUT SALA_MACHINES_POST_MAX_BODY; do
    grep -q "^#$k=" "$ROOT/config.example" && ok "config.example lists $k" || bad "config.example lacks $k"
done
grep -q 'machines.json' "$ROOT/lib/heartbeat.sh" && grep -q 'machines.json' "$ROOT/docs/heartbeat-store.md" && ok "the heartbeat header and docs/heartbeat-store.md name the file" || bad "docs"

[ "$fail" = 0 ] && echo "machinespost: pass" || echo "machinespost: FAIL"
exit $fail
