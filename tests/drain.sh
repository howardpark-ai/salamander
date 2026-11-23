#!/usr/bin/env bash
# Drain mode (lib/hook.sh `hook pre-tool`, the waiting text in lib/common.sh): while a relaunch waits for a session (waiting/<uuid>), its OWN turn may
# not start work that outlives the turn: a background subagent (Agent or Task with run_in_background true), a Monitor, a Bash call with
# run_in_background true. The hook denies them (permissionDecision deny, never ask) with the way out in the reason.
# Checks: each of the five calls denied while the session waits (the JSON shape, the reason says finish the turn / `sala note` / `sala ready` /
# the refusal ends with the relaunch and names the call and the relaunch's kind, and does not carry the command's text); the same calls allowed with
# nothing waiting, while ANOTHER session waits, and after the flag is cleared; a call carrying agent_id allowed (each of the three); foreground work allowed
# (a foreground Agent or Bash, run_in_background false, `sala note`, `sala ready`, TaskStop, Read, and a command that merely quotes the word in its text);
# SALA_DRAIN=off (environment and config file) allows; garbage allows (empty, not JSON, an array, no session id, a short or unsafe id, a cut input);
# a large input (an Agent prompt of 300 KB) still decided; an unwritable log and a missing flag-reading helper never change an allow into a deny;
# one log line per refusal with the session and the tool and never the command; the reason's text override; the fleet guard still denies a reboot typed
# in a Bash call while a flag is up, and a Bash call that is no guarded word stays allowed; with nothing waiting the hook starts no process (empty PATH);
# the waiting line says new background work is refused (and says the older request with SALA_DRAIN=off).
# No tmux, no claude, nothing is killed: the hook reads JSON on stdin, the flags are files under an isolated HOME.
# Usage: bash tests/drain.sh   (exit 0 = pass; seconds)
set -u
unset TMUX TMUX_PANE XDG_STATE_HOME SALA_STATE_DIR SALA_RELAUNCH_WAITING_TEXT SALA_DRAIN SALA_DRAIN_DENY_TEXT SALA_LOG_DIR
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC
exec 8< "$HOME"; flock -n 8 || { rm -rf "$HOME"; exit 1; }          # the temp folder is locked for the run (systemd-tmpfiles ageing honors it)
trap 'rm -rf "$HOME"' EXIT
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT"
SALA="$ROOT/bin/salamander"
mkdir -p "$HOME/.claude"
. "$ROOT/lib/common.sh"
WAITD="$SALA_WAITING_DIR"; LOG="$HOME/.claude/salamander-drain.log"
U1=$(uuid 1); U2=$(uuid 2)
MARK=SECRETMARK-4417        # a word that must never come back in a reason or in the log

pay() {  # <session id> <tool> <tool_input json> [extra top-level json fields] → a PreToolUse input in the CLI's shape (the id, the path and the tool lead it)
    python3 -c '
import json, sys
d = {"session_id": sys.argv[1], "transcript_path": "/srv/sess/projects/p/%s.jsonl" % sys.argv[1], "cwd": "/srv/work", "permission_mode": "default",
     "hook_event_name": "PreToolUse", "tool_name": sys.argv[2], "tool_input": json.loads(sys.argv[3]), "tool_use_id": "toolu_01"}
if len(sys.argv) > 4: d.update(json.loads(sys.argv[4]))
print(json.dumps(d))' "$@"
}
pre() { "$SALA" hook pre-tool; }                                       # the payload on stdin → the hook's stdout
verdict() {  # <hook stdout> → "deny" when it is a PreToolUse deny, "allow" when it printed nothing, "other:<text>" otherwise
    if [ -z "$1" ]; then echo allow; return; fi
    python3 -c 'import json, sys
try: d = json.loads(sys.argv[1])["hookSpecificOutput"]
except Exception: print("other:" + sys.argv[1][:80]); sys.exit(0)
print("deny" if d.get("hookEventName") == "PreToolUse" and d.get("permissionDecision") == "deny" and d.get("permissionDecisionReason") else "other:" + sys.argv[1][:80])' "$1"
}
reason() { python3 -c 'import json, sys; print(json.loads(sys.argv[1])["hookSpecificOutput"]["permissionDecisionReason"])' "$1"; }
chk() {  # <expected allow|deny> <label> <payload> [env assignments…] → one check
    local want="$1" label="$2" p="$3" out v; shift 3
    out=$(printf '%s' "$p" | env "$@" "$SALA" hook pre-tool 2>&1); rc=$?
    v=$(verdict "$out")
    [ "$rc" = 0 ] && [ "$v" = "$want" ] && ok "$label: $want" || bad "$label: wanted $want, got $v (rc=$rc) $out"
}
lines() { local n=0 l; [ -s "$LOG" ] && { while IFS= read -r l; do n=$((n + 1)); done < "$LOG"; }; echo "$n"; }

BG_AGENT='{"description":"build it","prompt":"do the work '$MARK'","subagent_type":"general-purpose","run_in_background":true}'
FG_AGENT='{"description":"build it","prompt":"do the work","subagent_type":"general-purpose"}'
BG_BASH='{"command":"sleep 600 # '$MARK'","run_in_background":true}'
MON='{"command":"tail -f /tmp/x.log # '$MARK'","description":"watch","persistent":true}'

echo "== nothing waits for anyone: every call is allowed"
chk allow "background Agent, no flag"       "$(pay "$U1" Agent "$BG_AGENT")"
chk allow "Monitor, no flag"                "$(pay "$U1" Monitor "$MON")"
chk allow "background Bash, no flag"        "$(pay "$U1" Bash "$BG_BASH")"

echo "== a relaunch waits for session 1: its own background work is refused"
waiting_raise "$U1" recycle set-1 $$
chk deny "background Agent"                 "$(pay "$U1" Agent "$BG_AGENT")"
chk deny "background Task (an older CLI)"   "$(pay "$U1" Task "$BG_AGENT")"
chk deny "Monitor"                          "$(pay "$U1" Monitor "$MON")"
chk deny "background Bash"                  "$(pay "$U1" Bash "$BG_BASH")"
chk deny "background Bash, pretty-printed JSON" "$(pay "$U1" Bash "$BG_BASH" | python3 -c 'import json, sys; print(json.dumps(json.load(sys.stdin), indent=2))')"
n=$(lines); [ "$n" = 5 ] && ok "one log line per refusal (5)" || bad "log lines: $n"
out=$(pay "$U1" Agent "$BG_AGENT" | pre); r=$(reason "$out")
[[ $r == *"background subagent"* ]] && [[ $r == *"finish"* || $r == *"Finish this turn"* ]] && [[ $r == *'sala note "<next step>"'* ]] && [[ $r == *'`sala ready`'* ]] && [[ $r == *"ends when the relaunch is done"* ]] \
    && ok "the reason names the call, says finish the turn, sala note, sala ready and that it ends with the relaunch" || bad "reason: $r"
[[ $r == *"recycle is waiting"* || $r == *"recycle"* ]] && ok "the reason names the relaunch's kind (recycle)" || bad "kind missing: $r"
[[ $out != *"$MARK"* ]] && ok "the reason does not carry the call's text" || bad "the call's text came back: $out"
for t in Monitor Bash; do
    inp=$(pay "$U1" $t "$([ $t = Bash ] && echo "$BG_BASH" || echo "$MON")"); out=$(printf '%s' "$inp" | pre); r=$(reason "$out")
    case $t in Monitor) w="a monitor";; Bash) w="a background shell command";; esac
    [[ $r == *"$w"* ]] && ok "$t: the reason says $w" || bad "$t reason: $r"
done
python3 -c 'import json, sys; json.loads(sys.argv[1])' "$out" 2>/dev/null && ok "the deny is one valid JSON line" || bad "not JSON: $out"
[ "$(printf '%s\n' "$out" | wc -l)" = 1 ] && ok "and one line" || bad "lines in the answer"
[ -s "$LOG" ] && ! grep -q "$MARK" "$LOG" && grep -q "$U1" "$LOG" && grep -q "refused Agent" "$LOG" && grep -q "refused Monitor" "$LOG" && grep -q "refused Bash" "$LOG" \
    && ok "the log names the session and the tool, never the command" || bad "log: $(cat "$LOG" 2>/dev/null)"
waiting_raise "$U1" reboot set-2 $$
out=$(pay "$U1" Agent "$BG_AGENT" | pre); r=$(reason "$out")
[[ $r == *"reboot of $(hostname)"* ]] && ok "a reboot's flag: the reason names the reboot" || bad "reboot kind: $r"
waiting_raise "$U1" recycle set-3 $$
LOGN=$(lines)

echo "== what stays allowed while it waits"
chk allow "foreground Agent"                "$(pay "$U1" Agent "$FG_AGENT")"
chk allow "Agent with run_in_background false" "$(pay "$U1" Agent '{"description":"x","prompt":"y","run_in_background":false}')"
chk allow "foreground Bash"                 "$(pay "$U1" Bash '{"command":"ls -la","description":"list"}')"
chk allow "Bash with run_in_background false" "$(pay "$U1" Bash '{"command":"ls","run_in_background":false}')"
chk allow "sala note"                       "$(pay "$U1" Bash '{"command":"sala note \"next: merge the PR\"","description":"leave a note"}')"
chk allow "sala ready"                      "$(pay "$U1" Bash '{"command":"sala ready"}')"
chk allow "TaskStop"                        "$(pay "$U1" TaskStop '{"task_id":"b1"}')"
chk allow "Read"                            "$(pay "$U1" Read '{"file_path":"/etc/hostname"}')"
chk allow "a command that only quotes the flag's name" "$(pay "$U1" Bash '{"command":"echo \"run_in_background\": true"}')"
chk allow "an Agent prompt that quotes it"  "$(pay "$U1" Agent '{"description":"x","prompt":"set \"run_in_background\": true when you start it"}')"
chk allow "a Bash call that quotes agent_id and is still foreground" "$(pay "$U1" Bash '{"command":"echo \"agent_id\": 1"}')"
n=$(lines); [ "$n" = "$LOGN" ] && ok "none of these logged ($LOGN lines, as before)" || bad "log lines now: $n, was $LOGN"

echo "== a call inside a subagent (agent_id) is the subagent's own: never refused"
chk allow "subagent's background Bash"      "$(pay "$U1" Bash "$BG_BASH" '{"agent_id":"agent-7","agent_type":"general-purpose"}')"
chk allow "subagent's Monitor"              "$(pay "$U1" Monitor "$MON" '{"agent_id":"agent-7"}')"
chk allow "subagent's background Agent"     "$(pay "$U1" Agent "$BG_AGENT" '{"agent_id":"agent-7"}')"
chk allow "subagent's background Task, agent_id after a long input" "$(pay "$U1" Task "$(python3 -c 'import json; print(json.dumps({"prompt": "p" * 60000, "run_in_background": True}))')" '{"agent_id":"agent-9"}')"
chk deny "the session's own call after theirs" "$(pay "$U1" Agent "$BG_AGENT")"

echo "== another session, a cleared flag, the owner's switch"
chk allow "session 2 (no flag of its own) background Agent" "$(pay "$U2" Agent "$BG_AGENT")"
chk allow "session 2 Monitor"               "$(pay "$U2" Monitor "$MON")"
chk allow "SALA_DRAIN=off (environment)"    "$(pay "$U1" Agent "$BG_AGENT")" SALA_DRAIN=off
chk allow "SALA_DRAIN=0"                    "$(pay "$U1" Monitor "$MON")" SALA_DRAIN=0
chk deny "SALA_DRAIN=on"                    "$(pay "$U1" Agent "$BG_AGENT")" SALA_DRAIN=on
printf 'SALA_DRAIN=off\n' > "$HOME/cfg-off"
chk allow "SALA_DRAIN=off in the config file" "$(pay "$U1" Bash "$BG_BASH")" SALA_CONFIG="$HOME/cfg-off"
printf '# nothing about drain\nSALA_OWNER_NAME=Tester\n' > "$HOME/cfg-other"
chk deny "a config file that does not mention it: on by default" "$(pay "$U1" Bash "$BG_BASH")" SALA_CONFIG="$HOME/cfg-other"
printf 'SALA_DRAIN_DENY_TEXT='"'"'Not now: <call> (<what>) with a "quote" and a \\ backslash.'"'"'\n' > "$HOME/cfg-text"
out=$(pay "$U1" Agent "$BG_AGENT" | SALA_CONFIG="$HOME/cfg-text" "$SALA" hook pre-tool); r=$(reason "$out" 2>/dev/null)
[ "$r" = 'Not now: a background subagent (recycle) with a "quote" and a \ backslash.' ] && ok "SALA_DRAIN_DENY_TEXT words the reason (the quote and the backslash survive the JSON)" || bad "text override: $out"
waiting_clear "$U1"
chk allow "background Agent after the flag is cleared" "$(pay "$U1" Agent "$BG_AGENT")"
chk allow "Monitor after the flag is cleared" "$(pay "$U1" Monitor "$MON")"
waiting_raise "$U1" recycle set-4 $$

echo "== doubt allows: garbage, a cut input, an id that is no id"
chk allow "empty input"                     ""
chk allow "not JSON"                        "not json at all"
chk allow "a JSON array"                    "[1,2]"
chk allow "no session id"                   '{"tool_name":"Agent","tool_input":{"run_in_background":true}}'
chk allow "no tool name, no session id"     '{"tool_input":{"run_in_background":true}}'
chk allow "a short session id"              "$(pay abc Agent "$BG_AGENT")"
chk allow "an id with a path in it"         "$(pay '../../etc/passwd' Agent "$BG_AGENT")"
chk allow "an id with a slash and dots, 8 characters or more" "$(pay '..%2f..%2fetc%2fpasswd' Agent "$BG_AGENT")"
chk allow "a cut input (the JSON ends inside a string)" '{"session_id":"'"$U1"'","tool_name":"Agent","tool_input":{"prompt":"abc'
chk allow "a tool name of another shape"    "$(pay "$U1" mcp__x__y '{"run_in_background":true}')"
chk deny "a cut input that still names the session and a Monitor" '{"session_id":"'"$U1"'","tool_name":"Monitor","tool_input":{"command":"tail'
bigpay() {  # <session id> <background true|false> → an Agent input with a prompt of 300 KB (past the 128 KB one argument can carry, so built whole by python)
    python3 -c '
import json, sys
print(json.dumps({"session_id": sys.argv[1], "transcript_path": "/x/y.jsonl", "cwd": "/x", "hook_event_name": "PreToolUse", "tool_name": "Agent",
                  "tool_input": {"description": "d", "prompt": "x" * 300000, "run_in_background": sys.argv[2] == "true"}, "tool_use_id": "toolu_02"}))' "$1" "$2"
}
chk deny "an Agent prompt of 300 KB"        "$(bigpay "$U1" true)"
chk allow "the same prompt, foreground"     "$(bigpay "$U1" false)"
chk deny "an unwritable log never turns the answer into an allow" "$(pay "$U1" Agent "$BG_AGENT")" SALA_LOG_DIR=/dev/null/nope
mkdir -p "$HOME/rootx/bin" "$HOME/rootx/lib"; cp "$ROOT/bin/salamander" "$HOME/rootx/bin/salamander"; cp "$ROOT/lib/hook.sh" "$HOME/rootx/lib/hook.sh"   # a checkout with no common.sh
out=$(printf '%s' "$(pay "$U1" Agent "$BG_AGENT")" | env SALA_BIN="$HOME/rootx/bin/salamander" "$HOME/rootx/bin/salamander" hook pre-tool 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok "a hook that cannot load its library allows, silent, exit 0" || bad "missing library: rc=$rc $out"
out=$(printf '%s' "$(pay "$U1" Agent "$BG_AGENT")" | env SALA_BIN="$HOME/rootx/bin/salamander" SALA_CONFIG="$HOME/cfg-nonexistent" "$HOME/rootx/bin/salamander" hook pre-tool 2>&1); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok "(the same with a config path that is not there)" || bad "rc=$rc $out"

echo "== the fleet guard is untouched, with a flag up and without"
chk deny "sudo reboot, a flag up"           "$(pay "$U1" Bash '{"command":"sudo reboot"}')"
chk allow "ls, a flag up"                   "$(pay "$U1" Bash '{"command":"ls /tmp"}')"
chk deny "sudo reboot, session 2"           "$(pay "$U2" Bash '{"command":"sudo reboot"}')"
waiting_clear_all
chk deny "sudo reboot, no flag"             "$(pay "$U1" Bash '{"command":"sudo reboot"}')"
chk allow "a Read with a guarded word, no flag" "$(pay "$U1" Read '{"file_path":"/tmp/reboot"}')"
chk allow "background Agent, no flag again" "$(pay "$U1" Agent "$BG_AGENT")"

echo "== the cost: nothing waits, nothing is started"
BASH_BIN=$(command -v bash)
quiet() {  # <payload> → 0 when the hook, run with an empty PATH, prints nothing and exits 0: any program it started would be "command not found" on stderr
    local o; o=$(printf '%s' "$1" | env -i HOME="$HOME" SALA_BIN="$SALA" SALA_ROOT="$ROOT" PATH=/nonexistent "$BASH_BIN" "$SALA" hook pre-tool 2>&1); qrc=$?
    [ "$qrc" = 0 ] && [ -z "$o" ]
}
quiet "$(pay "$U1" Agent "$BG_AGENT")" && ok "a background Agent with nothing waiting: no output, no command run (empty PATH)" || bad "agent path printed or ran something: rc=$qrc"
quiet "$(pay "$U1" Monitor "$MON")" && ok "a Monitor with nothing waiting: the same" || bad "monitor path: rc=$qrc"
quiet "$(pay "$U1" Read '{"file_path":"/tmp/x"}')" && ok "a Read with nothing waiting: the same" || bad "read path: rc=$qrc"
quiet "$(pay "$U1" Bash '{"command":"ls -la","run_in_background":true}')" && ok "a background Bash with nothing waiting and no guarded word: the same" || bad "bash path: rc=$qrc"
waiting_raise "$U1" recycle set-5 $$
quiet "$(pay "$U1" Read '{"file_path":"/tmp/x"}')" && ok "a Read while a flag stands: no command run either" || bad "read with flag: rc=$qrc"
quiet "$(pay "$U1" Agent "$FG_AGENT")" && ok "a foreground Agent while a flag stands: no command run" || bad "fg agent with flag: rc=$qrc"
waiting_clear_all

echo "== the waiting line says it"
txt=$(env -u SALA_RELAUNCH_WAITING_TEXT -u SALA_DRAIN bash -c '. "$1/lib/common.sh"; printf "%s" "$SALA_RELAUNCH_WAITING_TEXT"' _ "$ROOT")
[[ $txt == *"a new background subagent, monitor or background shell is refused until the relaunch"* ]] && [[ $txt == *"sala ready"* ]] && ok "default: a new background subagent, monitor or background shell is refused until the relaunch" || bad "line: $txt"
txt=$(env -u SALA_RELAUNCH_WAITING_TEXT SALA_DRAIN=off bash -c '. "$1/lib/common.sh"; printf "%s" "$SALA_RELAUNCH_WAITING_TEXT"' _ "$ROOT")
[[ $txt == *"start no new subagent, monitor or background task until you are relaunched"* ]] && [[ $txt != *"is refused"* ]] && ok "SALA_DRAIN=off: the older request, nothing said about a refusal" || bad "line off: $txt"
txt=$(env -u SALA_RELAUNCH_WAITING_TEXT -u SALA_DRAIN bash -c '. "$1/lib/common.sh"; waiting_raise '"$U1"' recycle s 1; relaunch_text recycle' _ "$ROOT")
[[ $txt == "[sala] A recycle is waiting for this session."* ]] && ok "relaunch_text puts the kind in" || bad "relaunch_text: $txt"
out=$(waiting_raise "$U2" recycle s-6 $$; printf '%s' "$(pay "$U2" Agent '{"description":"x","prompt":"y"}')" | "$SALA" hook post-tool)
[[ $out == *"is refused until the relaunch"* ]] && ok "the PostToolUse hook tells the session once, in these words" || bad "post-tool: $out"
waiting_clear_all
"$SALA" hook 2>&1 | grep -q "hook pre-tool.*Bash|Agent|Task|Monitor" && ok "hook usage names the matcher" || bad "hook usage"

echo; [ "$fail" = 0 ] && echo "drain: pass" || echo "drain: FAIL"
exit $fail
