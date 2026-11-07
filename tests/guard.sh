#!/usr/bin/env bash
# The fleet guard (`salamander hook pre-tool`, lib/guard.py): a table of Bash commands → allow or deny, through the
# real hook with a PreToolUse payload on stdin. Checks: reboot, CLI update, tmux kill-* on the fleet's server and kill of a
# claude process are denied with the documented JSON and the `sala op … --words` fix in the reason (Thu Oct 15th
# 2026: the queue's verb for the kind — update, retire — never the master or `sala cue`; a reboot is not queued, so its
# reason says the owner runs `sala reboot --go` in person and never names `sala op reboot`); near misses pass, one row
# per kind (echo, grep and git words, a heredoc's body, a comment, other installers, private tmux servers, sala's own
# verbs, $(pgrep …) and xargs forms, ssh); a literal pid is judged by /proc (a process named claude vs not), a process
# group too; `bash -c` strings are checked; the master's pane is exempt and another pane is not, and with no master
# configured no pane is; `kill <pid>` of the claude of a throwaway the calling session started itself (registry spawned_by)
# passes and every other stop stays denied; a tmux window, pane or session group placed into a session other than
# the caller's own is denied and one into the caller's own passes; malformed input fails open. Isolated HOME, a private tmux server with -f /dev/null (never the fleet's).
set -u
unset TMUX TMUX_PANE SALA_TMUX_SOCKET
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
export HOME=$(mktemp -d); mkdir -p "$HOME/bin" "$HOME/.config/salamander"
exec 8< "$HOME"; flock -n 8   # the temporary folder is locked while the suite runs (systemd-tmpfiles ageing honours the flock)
export SALA_CONFIG="$HOME/.config/salamander/config"; : > "$SALA_CONFIG"
SALA="$ROOT/bin/salamander"; SOCK="sala-guard-$$"; T="tmux -L $SOCK -f /dev/null"
PIDS=()
cleanup() { local p; for p in ${PIDS[@]+"${PIDS[@]}"}; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done; $T kill-server 2>/dev/null; tmux_socket_rm "$SOCK"; rm -rf "$HOME"; true; }
trap cleanup EXIT

payload() { python3 -c 'import json,sys; print(json.dumps({"session_id":"u1","transcript_path":"/home/x/.claude/projects/p/u1.jsonl","cwd":"/tmp","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":sys.argv[1],"description":"t"}}))' "$1"; }
hook() { payload "$1" | "$SALA" hook pre-tool; }       # <command> → the hook's stdout
verdict() {  # <command> → "deny" / "allow" / "bad:<why>"
    local out; out=$(hook "$1"); [ -z "$out" ] && { echo allow; return; }
    printf '%s' "$out" | python3 -c 'import json,sys
d=json.load(sys.stdin)["hookSpecificOutput"]
r = d["permissionDecisionReason"]
rb = "A reboot is not queued: Rowan runs `sala reboot --go` in the web UI" in r
fix = ("sala reboot --status" in r and "sala op " not in r) if rb else ("sala op " in r and "--words" in r)
ok = d["hookEventName"]=="PreToolUse" and d["permissionDecision"]=="deny" and fix and "sala cue" not in r
print("deny" if ok else "bad:"+json.dumps(d))' 2>/dev/null || echo "bad:$out"
}
reason() { hook "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecisionReason"])' 2>/dev/null; }
expect() {  # <deny|allow> <command> [label]
    local v; v=$(verdict "$2")
    [ "$v" = "$1" ] && ok "$1  ${3:-$2}" || bad "want $1, got $v: ${3:-$2}"
}

# a "claude" process and a plain one, for the /proc checks; a claude leading its own process group
printf '#!/bin/bash\nsleep "$1"\ntrue\n' > "$HOME/bin/claude"; cp "$HOME/bin/claude" "$HOME/bin/notclaude"; chmod +x "$HOME/bin/claude" "$HOME/bin/notclaude"   # comm = the script's name
"$HOME/bin/claude" 300 & CL=$!; PIDS+=("$CL")
"$HOME/bin/notclaude" 300 & NC=$!; PIDS+=("$NC")
setsid "$HOME/bin/claude" 300 & PIDS+=("$!")
waitfor "[ \"\$(cat /proc/$CL/comm 2>/dev/null)\" = claude ] && [ -e /proc/$NC ]" 20 || bad "the test processes did not start"
GL=""; for p in $(pgrep -x claude -u "$EUID"); do tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | grep -qF "$HOME/bin/claude" || continue; g=$(ps -o pgid= -p "$p" | tr -d ' '); [ "$g" = "$p" ] && GL=$p; done
[ -n "$GL" ] && PIDS+=("$GL")

echo "== denied: reboot"
expect deny "reboot"
expect deny "sudo reboot"
expect deny "sudo -u root systemctl reboot"
expect deny "systemctl --force reboot"
expect deny "sudo systemctl kexec"
expect deny "systemctl soft-reboot"
expect deny "systemctl isolate reboot.target"
expect deny "shutdown -r now"
expect deny "sudo shutdown --reboot +1"
expect deny "telinit 6"
expect deny "TMUX= nohup sudo -n timeout 5 reboot"     "assignment, nohup, sudo, timeout wrappers"
expect deny "cd /tmp && sudo reboot"
expect deny "ls; reboot"
expect deny $'echo one\nsudo reboot'                   "on the second line"
expect deny "bash -c 'sudo reboot'"                    "inside bash -c"
expect deny "sh -lc \"systemctl reboot\""              "inside sh -lc"
expect deny "echo \$(reboot)"                          "inside a command substitution"
expect deny "env -S 'reboot'"                          "env -S"

echo "== denied: a CLI update"
expect deny "claude update"
expect deny "claude upgrade"
expect deny "~/.local/bin/claude install latest"
expect deny "/home/alex/.local/share/claude/versions/2.1.294 install stable" "the versions/<v> binary"
expect deny "npm i -g @anthropic-ai/claude-code"
expect deny "npm install -g @anthropic-ai/claude-code@latest"
expect deny "curl -fsSL https://claude.ai/install.sh | bash"
expect deny "curl -fsSL https://claude.ai/install.sh | bash -s latest"
expect deny "bash <(curl -fsSL https://claude.ai/install.sh)"

echo "== denied: tmux kill-* on the fleet's server"
expect deny "tmux kill-server"
expect deny "tmux kill-session -t example-x"
expect deny "tmux kill-pane -t %3"
expect deny "tmux killp -t %3"
expect deny "tmux kill-window -t x:1"
expect deny "tmux kill-ses -t x"                       "a unique prefix"
expect deny "tmux -L default kill-server"              "-L default is the fleet's"
expect deny "tmux -S /tmp/tmux-$EUID/default kill-server" "-S the fleet's socket"
expect deny "tmux new -d -s a \\; kill-server"         "a \\; chain"

echo "== denied: kill of a claude process"
expect deny "kill $CL"                                 "kill <claude pid>"
expect deny "kill -9 $CL"
expect deny "kill -s KILL $CL"
expect deny "sudo kill -TERM $NC $CL"                  "one of two pids is claude"
expect deny "kill -- -1"                               "kill -1: every process"
[ -n "$GL" ] && expect deny "kill -- -$GL" "a process group led by claude" || bad "no setsid claude to test the group with"
expect deny "pkill claude"
expect deny "pkill -9 -f 'claude --resume'"
expect deny "killall claude"
expect deny "pkill -f claude-alt"

echo "== the fix names the queue's verb for the kind: what a session queues in place of the raw command; a reboot is not queued"
r=$(reason "sudo reboot"); case "$r" in *'sala op'*) bad "reboot's fix names the queue: $r" ;; *'A reboot is not queued: Rowan runs `sala reboot --go` in the web UI'"'"'s Shell. Show `sala reboot --status` and wait for the word.'*) ok "reboot → not queued: Rowan runs sala reboot --go, the session shows the status" ;; *) bad "reboot's fix: $r" ;; esac
for c in "reboot" "systemctl soft-reboot" "telinit 6"; do r=$(reason "$c"); case "$r" in *'sala op'*|'') bad "$c: $r" ;; *'is not queued'*) ok "$c → not queued" ;; *) bad "$c: $r" ;; esac; done
r=$(reason "claude update"); case "$r" in *'not queued'*) bad "update says not queued: $r" ;; esac
r=$(reason "claude update"); case "$r" in *'sala op update --from <you> --words'*) ok "a CLI update → sala op update" ;; *) bad "update's fix: $r" ;; esac
r=$(reason "tmux kill-session -t example-x"); case "$r" in *'sala op retire <session> --from <you> --words'*) ok "tmux kill-* → sala op retire <session>" ;; *) bad "tmux's fix: $r" ;; esac
r=$(reason "kill $CL"); case "$r" in *'sala op retire <session> (or revive --only <session> --force, to relaunch it) --from <you> --words'*) ok "kill of a claude → sala op retire <session>, or revive --only to relaunch" ;; *) bad "kill's fix: $r" ;; esac
case "$r" in *master*) bad "the reason still names the master: $r" ;; *) ok "no master and no sala cue in the reason: the queue is the one door" ;; esac

echo "== allowed: near misses"
expect allow "echo reboot"
expect allow "grep -rn 'tmux kill-server' lib/"
expect allow "git commit -m 'guard: deny reboot and claude update'"
expect allow $'cat <<EOF\nclaude update\nEOF\necho done'                          "a heredoc's body"
expect allow "ls # then reboot"                        "a trailing comment"
expect allow "npm install left-pad"
expect allow "systemctl --user status reboot.target"
expect allow "shutdown -c"                             "cancelling a shutdown"
expect allow "claude mcp list"
expect allow "curl -fsSL https://claude.ai/install.sh -o /tmp/install.sh" "downloading the installer only"
expect allow "man reboot"

echo "== allowed: private tmux servers"
expect allow "tmux -L sala-test-1 -f /dev/null kill-session -t a"
expect allow "tmux -S /tmp/private.sock kill-server"
expect allow "tmux list-sessions"
SALA_TMUX_SOCKET=/tmp/sala-guard-fleet-$$ expect deny "tmux -S /tmp/sala-guard-fleet-$$ kill-server" "SALA_TMUX_SOCKET names the fleet's socket (environment)"
echo "SALA_TMUX_SOCKET=/tmp/sala-guard-fleet-$$" > "$SALA_CONFIG"
expect deny "tmux -S /tmp/sala-guard-fleet-$$ kill-server" "SALA_TMUX_SOCKET from the config"
: > "$SALA_CONFIG"

echo "== allowed: kill that is not of claude, and forms it cannot read"
expect allow "kill $NC"                                "kill <a pid that is not claude>"
expect allow "kill -9 999999999"                       "a pid that does not exist"
expect allow "kill %1"
expect allow "kill \$(pgrep claude)"                   "\$(pgrep …): never run to decide"
expect allow "pgrep claude | xargs kill"
expect allow "pkill -f ~/.claude/hooks/x.sh"           "a path under ~/.claude"
expect allow "pkill -f harbor-sync"
expect allow "ssh box1 'claude update'"                 "ssh: not looked into"

echo "== allowed: sala's own verbs"
expect allow "~/.local/bin/sala update --fleet"
expect allow "SALA_X=1 ~/salamander/bin/salamander reboot --go"
expect allow "sala op spawn gamma-foo-main --project projects/foo --role front --mandate ~/m.md --from me --words 'make it'" "the queue's spawn verb"

echo "== the master's pane is exempt, another pane is not"
$T new-session -d -s the-master -x 80 -y 20 "sleep 300"; $T new-session -d -s worker -x 80 -y 20 "sleep 300"
MP=$($T list-panes -t =the-master -F '#{pane_id}'); WP=$($T list-panes -t =worker -F '#{pane_id}')
TSOCK="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"
echo "SALA_MASTER=the-master" > "$SALA_CONFIG"
v=$(TMUX="$TSOCK,1,0" TMUX_PANE="$MP" verdict "sudo reboot"); [ "$v" = allow ] && ok "the master's pane: sudo reboot allowed" || bad "master: $v"
v=$(TMUX="$TSOCK,1,0" TMUX_PANE="$WP" verdict "sudo reboot"); [ "$v" = deny ] && ok "another pane: denied" || bad "worker: $v"
v=$(TMUX="$TSOCK,1,0" TMUX_PANE="$WP" verdict "tmux kill-server"); [ "$v" = allow ] && ok "plain tmux kill-server from a pane on a private server (\$TMUX) passes" || bad "private \$TMUX: $v"
: > "$SALA_CONFIG"
v=$(TMUX="$TSOCK,1,0" TMUX_PANE="$MP" verdict "sudo reboot"); [ "$v" = deny ] && ok "no master configured: the former master's pane is denied like any other" || bad "no master, master's pane: $v"

echo "== a session may kill the claude of a throwaway it started itself (spawned_by)"
# a tmux session per case, each pane running a fake claude (comm = claude) as the pane's own process; the registry (the
# default path under the isolated HOME) says who started what. The guard only decides: nothing is killed here.
unset XDG_STATE_HOME SALA_SESSIONS_FILE SALA_SIDECAR
mkdir -p "$HOME/.local/state/salamander"
i=0; for n in owner thr-own thr-other thr-nospawner agent-own side-own thr-two; do i=$((i + 1)); $T new-session -d -s "$n" -x 80 -y 20 "exec env SALA_SESSION_ID=a$i $HOME/bin/claude 300"; done   # (each claude carries its registry row id, as spawn gives it)
$T new-session -d -s other-caller -x 80 -y 20 "sleep 300"
pidof_s() { $T list-panes -t "=$1" -F '#{pane_pid}'; }
waitfor "[ \"\$(cat /proc/\$($T list-panes -t =thr-two -F '#{pane_pid}')/comm 2>/dev/null)\" = claude ]" 20 || bad "the fake claude panes did not start"
OP=$($T list-panes -t =owner -F '#{pane_id}'); XP=$($T list-panes -t =other-caller -F '#{pane_id}')
P_OWN=$(pidof_s thr-own); P_OTHER=$(pidof_s thr-other); P_NOSP=$(pidof_s thr-nospawner); P_AGENT=$(pidof_s agent-own); P_SIDE=$(pidof_s side-own); P_ME=$(pidof_s owner); P_TWO=$(pidof_s thr-two)
cat > "$HOME/.local/state/salamander/sessions.json" <<JSON
{"schema": 1, "sessions": {
 "a1": {"id": "a1", "name": "owner", "state": "live", "project": null, "role": null, "side": null, "spawned_by": "other-caller"},
 "a2": {"id": "a2", "name": "thr-own", "state": "live", "project": null, "role": null, "side": null, "spawned_by": "owner"},
 "a3": {"id": "a3", "name": "thr-other", "state": "live", "project": null, "role": null, "side": null, "spawned_by": "other-caller"},
 "a4": {"id": "a4", "name": "thr-nospawner", "state": "live", "project": null, "role": null, "side": null, "spawned_by": null},
 "a5": {"id": "a5", "name": "agent-own", "state": "live", "project": "projects/x", "role": "front", "side": null, "spawned_by": "owner"},
 "a6": {"id": "a6", "name": "side-own", "state": "live", "project": null, "role": null, "side": 1, "spawned_by": "owner"},
 "a7": {"id": "a7", "name": "thr-two", "state": "live", "project": null, "role": null, "side": null, "spawned_by": "owner"},
 "a8": {"id": "a8", "name": "thr-two", "state": "live", "project": null, "role": null, "side": null, "spawned_by": "owner"},
 "a9": {"id": "a9", "name": "thr-dead", "state": "live", "project": null, "role": null, "side": null, "spawned_by": "owner"}}}
JSON
# a review finding: the owner's throwaway thr-dead has died (no tmux session of that name), and a victim is renamed to its name
$T new-session -d -s victim -x 80 -y 20 "exec env SALA_SESSION_ID=v9 $HOME/bin/claude 300"
$T new-session -d -s victim-noid -x 80 -y 20 "exec $HOME/bin/claude 300"
waitfor "[ \"\$(cat /proc/\$($T list-panes -t =victim-noid -F '#{pane_pid}')/comm 2>/dev/null)\" = claude ]" 20 || bad "the victim claude panes did not start"
P_VIC=$(pidof_s victim); P_VICN=$(pidof_s victim-noid)
ownv() { TMUX="$TSOCK,1,0" TMUX_PANE="$OP" verdict "$1"; }   # the command, run from the owner session's pane
v=$(ownv "kill $P_OWN"); [ "$v" = allow ] && ok "kill <pid> of the throwaway the caller started: allowed" || bad "own throwaway: $v"
v=$(ownv "kill -TERM $P_OWN"); [ "$v" = allow ] && ok "kill -TERM <pid> of it: allowed" || bad "own throwaway -TERM: $v"
v=$(ownv "kill -9 $P_OWN"); [ "$v" = allow ] && ok "kill -9 <pid> of it: allowed" || bad "own throwaway -9: $v"
v=$(ownv "sudo kill -TERM $P_OWN"); [ "$v" = allow ] && ok "under sudo: allowed" || bad "own throwaway sudo: $v"
v=$(ownv "kill $P_OTHER"); [ "$v" = deny ] && ok "another session's throwaway: denied" || bad "other's throwaway: $v"
v=$(ownv "kill $P_NOSP"); [ "$v" = deny ] && ok "a throwaway with no spawned_by: denied" || bad "no spawner: $v"
v=$(ownv "kill $P_AGENT"); [ "$v" = deny ] && ok "a project agent, even one the caller started: denied" || bad "project agent: $v"
v=$(ownv "kill $P_SIDE"); [ "$v" = deny ] && ok "a side session: denied" || bad "side session: $v"
v=$(ownv "kill $P_ME"); [ "$v" = deny ] && ok "the caller's own session: denied" || bad "caller itself: $v"
v=$(ownv "kill $P_TWO"); [ "$v" = deny ] && ok "two live rows of the name (ambiguous): denied" || bad "ambiguous: $v"
v=$(ownv "kill $P_OWN $P_OTHER"); [ "$v" = deny ] && ok "own throwaway and another's in one command: denied" || bad "mixed: $v"
v=$(ownv "kill $P_OWN; kill $P_AGENT"); [ "$v" = deny ] && ok "own throwaway, then a project agent: denied" || bad "chain: $v"
for byname in pkill killall; do   # the hook only reads these as text; nothing here runs them
    v=$(ownv "$byname claude"); [ "$v" = deny ] && ok "$byname by name from the owner: denied" || bad "$byname: $v"
done
v=$(ownv "kill -- -1"); [ "$v" = deny ] && ok "kill -1 from the owner: denied" || bad "kill -1: $v"
v=$(TMUX="$TSOCK,1,0" TMUX_PANE="$XP" verdict "kill $P_OWN"); [ "$v" = deny ] && ok "the same pid from a session that did not start it: denied" || bad "other caller: $v"
v=$(TMUX="$TSOCK,1,0" verdict "kill $P_OWN"); [ "$v" = deny ] && ok "no TMUX_PANE (no caller identity): denied" || bad "no pane: $v"
$T rename-session -t =victim thr-dead
v=$(ownv "kill $P_VIC"); [ "$v" = deny ] && ok "a victim renamed to a dead throwaway's name (its claude carries another row id): denied" || bad "renamed victim: $v"
$T kill-session -t =thr-dead
$T rename-session -t =victim-noid thr-dead
v=$(ownv "kill $P_VICN"); [ "$v" = deny ] && ok "a victim with no SALA_SESSION_ID renamed to that name: denied" || bad "renamed victim without id: $v"
$T kill-session -t =thr-dead
$T new-session -d -s thr-dead -x 80 -y 20 "exec env SALA_SESSION_ID=a9 $HOME/bin/claude 300"
waitfor "[ \"\$(cat /proc/\$($T list-panes -t =thr-dead -F '#{pane_pid}')/comm 2>/dev/null)\" = claude ]" 20 || bad "thr-dead did not start"
v=$(ownv "kill $(pidof_s thr-dead)"); [ "$v" = allow ] && ok "the process that does carry the row's id, under the same name: allowed" || bad "matching id: $v"
echo "SALA_MASTER=thr-own" > "$SALA_CONFIG"
v=$(ownv "kill $P_OWN"); [ "$v" = deny ] && ok "the master's session is never a throwaway to kill: denied" || bad "master: $v"
: > "$SALA_CONFIG"
echo '{"schema": 1, "sessions": {}}' > "$HOME/.local/state/salamander/sessions.json"
v=$(ownv "kill $P_OWN"); [ "$v" = deny ] && ok "no row in the registry: denied" || bad "no row: $v"
rm -f "$HOME/.local/state/salamander/sessions.json"
v=$(ownv "kill $P_OWN"); [ "$v" = deny ] && ok "no registry file: denied (falls back to the old rule)" || bad "no registry: $v"
r=$(TMUX="$TSOCK,1,0" TMUX_PANE="$OP" reason "kill $P_OTHER"); case "$r" in *'a throwaway you started yourself'*'goes through the queue'*) ok "the deny says which stop is allowed" ;; *) bad "deny text: $r" ;; esac

echo "== a window, pane or session group is never put into another session: tmux new-window · split-window · respawn-pane · join-pane · move-pane · break-pane · new-session -t"
# the private server stands in for the fleet's here (SALA_TMUX_SOCKET names it), so the rule reads the commands as the fleet's. Nothing runs: the hook only reads.
cat > "$HOME/.local/state/salamander/sessions.json" <<JSON
{"schema": 1, "sessions": {"a1": {"id": "a1", "name": "owner", "state": "live", "project": null, "role": null, "side": null, "spawned_by": "other-caller"}}}
JSON
THR_PANE=$($T list-panes -t =thr-other -F '#{pane_id}'); OWN_PANE=$OP
pv() {  # <command> → deny / allow, from the owner's pane on the "fleet" server
    local out; out=$(SALA_TMUX_SOCKET="$TSOCK" TMUX="$TSOCK,1,0" TMUX_PANE="$OP" hook "$1")
    [ -z "$out" ] && { echo allow; return; }
    case "$out" in *'"permissionDecision": "deny"'*) echo deny ;; *) echo "bad:$out" ;; esac
}
pexpect() { local v; v=$(pv "$2"); [ "$v" = "$1" ] && ok "$1  ${3:-$2}" || bad "want $1, got $v: ${3:-$2}"; }
pexpect deny  "tmux new-window -d -t thr-other: 'sleep 1'"      "new-window into another session"
pexpect deny  "tmux neww -t =thr-other: 'sleep 1'"              "the alias, an exact name"
pexpect deny  "tmux new-window -dt thr-other: 'sleep 1'"        "a clustered -dt"
pexpect deny  "tmux new-window -d -t thr-other:3 'sleep 1'"     "a window index in another session"
pexpect deny  "tmux new-window -d -t $THR_PANE 'sleep 1'"       "a pane id of another session"
pexpect deny  "tmux split-window -t thr-other: 'sleep 1'"       "split-window"
pexpect deny  "tmux splitw -h -t $THR_PANE"                     "the alias, a pane id"
pexpect deny  "tmux respawn-pane -k -t $THR_PANE 'sleep 1'"     "respawn-pane"
pexpect deny  "tmux join-pane -s $OWN_PANE -t thr-other:"       "join-pane into another session"
pexpect deny  "tmux join-pane -s $THR_PANE -t owner:"           "join-pane from another session (its source)"
pexpect deny  "tmux move-pane -s $OWN_PANE -t thr-other:"       "move-pane"
pexpect deny  "tmux break-pane -s $THR_PANE"                    "break-pane of another session's pane"
pexpect deny  "tmux new-session -d -t thr-other"                "new-session -t groups with another session"
pexpect deny  "tmux new-window -t owner: \\; new-window -t thr-other:"  "a \\; chain whose second command is another session's"
pexpect deny  "cd /tmp && tmux new-window -d -t thr-other: 'sleep 1'"  "behind &&"
# round 3: a target with no colon, `=name`, a shadowing window, hidden options, chained words, a changed TMUX_PANE, more commands
pexpect deny  "tmux new-window -t =thr-other 'x'"               "=name with no colon (display -t does not resolve it as a session)"
pexpect deny  "tmux new-session -d -t=thr-other"                "new-session -t=name, clustered with the value"
pexpect deny  "tmux new-session -d -t thr-other"                "new-session -t name with no colon"
$T new-window -d -t owner: -n thr-other 'sleep 300'
pexpect deny  "tmux new-window -t thr-other 'x'"                "a window in the caller's own session named like the victim does not shadow the lookup"
pexpect deny  "tmux split-window -t thr-other 'x'"              "the same shadow, split-window"
$T kill-window -t owner:thr-other
pexpect deny  "tmux split-window -p 50 -t thr-other:"           "split-window -p (a percentage) before the target"
pexpect deny  "tmux split-window -f -t thr-other:"              "split-window -f takes no argument: its -t is still read"
pexpect deny  "tmux split-window -l 5 -t thr-other:"            "split-window -l"
pexpect deny  "tmux join-pane -p 50 -s $OWN_PANE -t thr-other:" "join-pane -p"
pexpect deny  "tmux new-win -t thr-other: x"                    "an unambiguous prefix of new-window"
pexpect deny  "tmux split-w -t thr-other:"                      "an unambiguous prefix of split-window"
pexpect deny  "tmux new-window -t owner:\\; new-window -t thr-other:"  "a word that ends in a ; (owner:\\;) ends the first command"
pexpect deny  "TMUX_PANE=$THR_PANE tmux new-window -d 'x'"      "TMUX_PANE assigned in front: the default target moves to another session"
pexpect deny  "env TMUX_PANE=$THR_PANE tmux new-window -d 'x'"  "env TMUX_PANE=... in front"
pexpect deny  "env -u TMUX_PANE tmux new-window -d 'x'"         "env -u TMUX_PANE in front"
pexpect deny  "export TMUX_PANE=$THR_PANE; tmux new-window -d 'x'"  "TMUX_PANE exported on the line before"
pexpect deny  "tmux swap-pane -s $OWN_PANE -t $THR_PANE"        "swap-pane with another session's pane"
pexpect deny  "tmux swapp -t thr-other:"                        "swap-pane, the alias"
pexpect deny  "tmux swap-window -s owner:0 -t thr-other:0"      "swap-window"
pexpect deny  "tmux move-window -s owner:0 -t thr-other:"       "move-window"
pexpect deny  "tmux link-window -s owner:0 -t thr-other:"       "link-window"
pexpect deny  "tmux rename-session -t thr-other x"              "rename-session aimed at another session"
pexpect deny  "tmux rename -t =thr-other x"                     "rename-session, the alias, an exact name"
pexpect allow "tmux rename-session -t owner x"                  "rename-session of the caller's own session"
pexpect allow "tmux rename-session x"                           "rename-session with no -t: the caller's own"
pexpect allow "tmux new-window -t =owner 'x'"                   "=name of the caller's own session, no colon"
pexpect allow "tmux swap-pane -s $OWN_PANE -t $OWN_PANE"        "swap-pane inside the caller's own session"
pexpect allow "tmux move-window -s owner:1 -t owner:5"          "move-window inside the caller's own session"
pexpect allow "tmux split-window -p 50 -t owner:"               "split-window -p in the caller's own session"
pexpect allow "tmux split-window -f -t owner:"                  "split-window -f in the caller's own session"
pexpect allow "tmux new-window -d -t owner: 'sleep 1'"          "new-window into the caller's own session"
pexpect allow "tmux new-window -d 'sleep 1'"                    "no -t: the caller's own session"
pexpect allow "tmux new-window -d -t : 'sleep 1'"               "-t with no session part"
pexpect allow "tmux split-window -t $OWN_PANE"                  "the caller's own pane id"
pexpect allow "tmux new-session -d -s scratch 'sleep 1'"        "new-session with no -t is unrelated"
pexpect allow "tmux new-window -d -t nosuch-session: 'sleep 1'" "a target that names nothing: cannot be told"
pexpect allow "tmux -L sala-test-1 -f /dev/null new-window -t thr-other:"  "a private server"
pexpect allow "tmux list-windows -t thr-other"                  "reading another session is not placing"
pexpect allow "tmux send-keys -t thr-other: x"                  "send-keys is not covered (sala's cue uses it)"
v=$(SALA_TMUX_SOCKET="$TSOCK" TMUX="$TSOCK,1,0" hook "tmux new-window -d -t thr-other: 'sleep 1'"); case "$v" in *deny*) ok "deny  no TMUX_PANE (no caller identity) and another session's target" ;; *) bad "no pane: $v" ;; esac
echo "SALA_MASTER=owner" > "$SALA_CONFIG"
pexpect allow "tmux new-window -d -t thr-other: 'sleep 1'"      "the master's own pane is exempt"
: > "$SALA_CONFIG"
r=$(SALA_TMUX_SOCKET="$TSOCK" TMUX="$TSOCK,1,0" TMUX_PANE="$OP" reason "tmux new-window -d -t thr-other: 'x'")
case "$r" in *'-t <you>:'*'sala spawn NAME'*'tmux -L <name> -f /dev/null'*) ok "the deny names what to do instead: own session, a bare sala spawn, a private server" ;; *) bad "deny text: $r" ;; esac

echo "== fail open"
for p in '' 'not json' '[1,2]' '{"tool_name":"Bash"}' '{"tool_name":"Bash","tool_input":{"command":7}}' '{"tool_name":"Read","tool_input":{"command":"reboot"}}'; do
    out=$(printf '%s' "$p" | "$SALA" hook pre-tool); rc=$?
    [ "$rc" = 0 ] && [ -z "$out" ] && ok "input '$p': allowed, exit 0" || bad "input '$p': rc=$rc out=$out"
done
"$SALA" hook pre-tool </dev/null >/dev/null 2>&1; [ $? = 0 ] && ok "empty stdin: exit 0 (the provision step's version probe)" || bad "empty stdin"

[ "$fail" = 0 ] && echo "guard: pass" || echo "guard: FAIL"
exit $fail
