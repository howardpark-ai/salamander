#!/usr/bin/env bash
# The busy hooks (lib/hook.sh): the Stop hook's record of a session's in-flight work, and the relaunch-waiting flag.
# Checks: `hook stop` from sample payloads (tasks, none, the field missing, malformed JSON, no session id) → a record or none,
# exit 0, nothing on stdout; a record stamped only once the registry flips to idle (the detached waiter; two waiters, the
# newer record wins); is_idle with a fresh record saying work in flight (a shell task; a subagent, a monitor, a workflow) →
# busy; with a fresh empty record → idle although the process has a child; with a stale record (the registry flipped since)
# → the old guesses; the parked fork still wins; the artifact watch Claude Code arms on publish not counted (alone it
# reads idle and `revive --only` relaunches the pane as it is, nothing sent to the session; beside a shell it reads busy; near
# misses still count; every label the CLI writes for a watch, "watch requested" and "re-armed on session resume" among
# them, alone reads idle). `hook post-tool`: silent without a flag (stdin untouched), the relaunch notice once per relaunch with
# one, again for a new relaunch, silent after the clear; pruning. A retry worker raising the flag
# for its pane, woken by the Stop hook's empty record (the ready path) and relaunching the pane long before its next tick,
# the flag down afterwards. (the words per kind, the config override of the text and the second ready-path run, which
# differed only in its words, were dropped.)
# Isolated HOME, a private tmux server started with -f /dev/null (never one that reads ~/.tmux.conf: continuum would restore
# the fleet into it), the compiled fake claude; no real session is touched.
# Usage: bash tests/busyhooks.sh   (exit 0 = pass; ~2 min)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_SET SALA_SET_SELF SALA_RECYCLE SALA_RETRY_WORKER SALA_RELAUNCH_KIND SALA_RELAUNCH_WAITING_TEXT
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"   # short timings, ok/bad/waitfor, tmux_socket_rm
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
mkdir -p "$HOME/.local/share/claude/versions"; cc -o "$HOME/.local/share/claude/versions/9.9.9" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (an EXIT trap may not exist yet here)
ln -s "$HOME/.local/share/claude/versions/9.9.9" "$HOME/.local/bin/claude"   # as the CLI installs it: the launcher target's name is the version
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.log"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="cat >> $POSTS"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off
SALA="$ROOT/bin/salamander"; SOCK="sala-busyhooks-$$"; T="tmux -L $SOCK -f /dev/null"; RLOG="$HOME/.claude/salamander-revive.log"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # this server stands in for the fleet's (common.sh, on_fleet_server)
KID=""
cleanup() {
    local f p; for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill "$(<"$f")" 2>/dev/null; done
    [ -n "$KID" ] && { pkill -P "$KID" 2>/dev/null; kill "$KID" 2>/dev/null; }
    $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    for p in $(pgrep -x claude); do [ "$HOME/.local/share/claude/versions/9.9.9" -ef "/proc/$p/exe" ] && kill -9 "$p" 2>/dev/null; done
    rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux    # the children (set -u) get the literal socket and the empty config
. "$ROOT/lib/common.sh"
BUSY="$SALA_BUSY_DIR"; WAITD="$SALA_WAITING_DIR"
row() {  # row <pid> <uuid> <status> <stamp ms> [parkedJobId] — a registry row as the CLI writes it
    printf '{"pid":%s,"sessionId":"%s","name":"t","status":"%s","statusUpdatedAt":%s,"tmux":"x:@0.%%0","version":"9.9.9"%s}\n' \
        "$1" "$2" "$3" "$4" "${5:+,\"parkedJobId\":\"$5\"}" > "$HOME/.claude/sessions/$1.json"
}
stop_hook() { printf '%s' "$1" | "$SALA" hook stop; }      # <payload> → the hook's exit code; its stdout is ours
post_hook() { printf '%s' "$1" | "$SALA" hook post-tool; }
rec() { awk -F= -v k="$2" '$1==k {print substr($0, length(k)+2); exit}' "$BUSY/$1" 2>/dev/null; }   # <uuid> <key>
flag() { awk -F= -v k="$2" '$1==k {print substr($0, length(k)+2); exit}' "$WAITD/$1" 2>/dev/null; }
U1=$(uuid 1); U2=$(uuid 2); U3=$(uuid 3)
WURL=https://claude.ai/artifact/EXAMPLEARTIFACTID; WURL2=https://claude.ai/code/artifact/aaaaaaaa-0000-4000-8000-0000000000a1
watch_task() { printf '{"id":"%s","type":"monitor","status":"running","description":"live updates for artifact %s (%s)"}' "$1" "${2:-$WURL}" "${3:-auto-armed on publish}"; }   # the real wording; <id> [url] [label]
# every label Claude Code 2.1.296 writes for an artifact watch (zjt; lib/common.sh, THE ARTIFACT WATCH)
WLABELS=("auto-armed on publish" "attached via /artifacts" "watch requested" "resume requested" "re-armed on session resume" "presence while editing via MCP" "watch requested; auto-replies since stopped")
ms_ago() { echo "$(( $(date +%s) - $1 ))000"; }   # a registry stamp (ms) from $1 s ago
LINE='[sala] A <what> is waiting for this session. Bring your work to a checkpoint. Stop your own background watches (TaskStop) and put what they were waiting for in a `sala note "<step>"` before `sala ready`. If a step must wait until after the relaunch, leave it with `sala note "<step>"` (or set the board item'\''s recycle flag), then run `sala ready` as the turn'\''s last call.'
workers() { local f n=0; for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill -0 "$(<"$f")" 2>/dev/null && n=$((n+1)); done; echo $n; }

echo "== hook stop: the record from sample payloads — exit 0 and nothing on stdout, whatever comes in"
bash -c 'sleep 900 & wait' & KID=$!; sleep 0.5     # a "claude" with a child process: the old guess reads it busy for ever
S1=$(ms_ago 60); row "$KID" "$U1" idle "$S1"
out=$(stop_hook "{\"session_id\":\"$U1\",\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"background_tasks\":[{\"id\":\"t1\",\"type\":\"shell\",\"status\":\"running\",\"description\":\"tail logs\",\"command\":\"tail -f /var/log/syslog\"}],\"session_crons\":[{\"id\":\"c1\",\"schedule\":\"0 9 * * 1-5\",\"recurring\":true,\"prompt\":\"check the build\"}]}"); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok "a task and a cron: exit 0, silent" || bad "rc=$rc out='$out'"
[ "$(rec "$U1" tasks)" = 1 ] && [ "$(rec "$U1" crons)" = 1 ] && grep -qx 'task=shell running: tail logs (tail -f /var/log/syslog)' "$BUSY/$U1" && grep -qx 'cron=0 9 \* \* 1-5 recurring: check the build' "$BUSY/$U1" \
    && ok "record: tasks=1 crons=1, the task and the cron named" || bad "record: $(slurp "$BUSY/$U1")"
[ "$(rec "$U1" flip)" = "$S1" ] && ok "the row was idle at hook time: stamped with its flip at once" || bad "flip=$(rec "$U1" flip), want $S1"
is_idle "$KID"; [ $? = 1 ] && ok "is_idle: 1" || bad "is_idle on a busy record"
stop_hook "{\"session_id\":\"$U1\",\"background_tasks\":[{\"id\":\"a\",\"type\":\"subagent\",\"status\":\"running\",\"description\":\"review the diff\",\"agent_type\":\"code-reviewer\"},{\"id\":\"m\",\"type\":\"monitor\",\"status\":\"running\",\"description\":\"watch CI\",\"server\":\"github\",\"tool\":\"checks\"},{\"id\":\"w\",\"type\":\"workflow\",\"status\":\"pending\",\"description\":\"the release\",\"name\":\"release\"}]}"
is_idle "$KID"; [ $? = 1 ] && [ "$(rec "$U1" tasks)" = 3 ] && ok "subagent, monitor, workflow: each counts as work in flight (is_idle: 1)" || bad "3 tasks: $(slurp "$BUSY/$U1")"
# the watch Claude Code arms by itself on publish (the real description) is not work in flight; beside anything else it
# changes nothing; the same words on another monitor, or more words, still count
stop_hook "{\"session_id\":\"$U1\",\"background_tasks\":[$(watch_task w1),$(watch_task w2 "$WURL2")]}"
[ -z "$(is_idle_reason "$KID")" ] && is_idle "$KID" && [ "$(busy_watches "$KID" "$U1" | tr '\n' ' ')" = "$WURL $WURL2 " ] \
    && ok "only auto-armed artifact watches: idle (is_idle: 0), both URLs kept" || bad "watch only: why='$(is_idle_reason "$KID")' watches='$(busy_watches "$KID" "$U1")'"
# every label the CLI writes for a watch: a watch armed on request, and the auto-armed one as it
# comes back after a relaunch ("re-armed on session resume"), are no more work in flight than the one armed on publish
nl=0; for l in "${WLABELS[@]}"; do
    stop_hook "{\"session_id\":\"$U1\",\"background_tasks\":[$(watch_task w1 "$WURL2" "$l")]}"
    if [ -z "$(is_idle_reason "$KID")" ] && is_idle "$KID" && [ "$(busy_watches "$KID" "$U1")" = "$WURL2" ]; then nl=$((nl+1)); else bad "label '$l' alone: why='$(is_idle_reason "$KID")' watches='$(busy_watches "$KID" "$U1")'"; fi
done
[ "$nl" = "${#WLABELS[@]}" ] && ok "each of the $nl watch labels alone: idle (is_idle: 0), the URL kept"
stop_hook "{\"session_id\":\"$U1\",\"background_tasks\":[$(watch_task w1 "$WURL" "watch requested")]}"
[ -z "$(is_idle_reason "$KID")" ] && is_idle "$KID" && ok "a watch requested by the session, alone: idle" || bad "watch requested: '$(is_idle_reason "$KID")'"
stop_hook "{\"session_id\":\"$U1\",\"background_tasks\":[$(watch_task w1 "$WURL" "re-armed on session resume")]}"
[ -z "$(is_idle_reason "$KID")" ] && is_idle "$KID" && ok "the watch re-armed on the resume, alone: idle (the next recycle is not blocked)" || bad "re-armed: '$(is_idle_reason "$KID")'"
stop_hook "{\"session_id\":\"$U1\",\"background_tasks\":[$(watch_task w1),{\"id\":\"t\",\"type\":\"shell\",\"status\":\"running\",\"description\":\"a build\"}]}"
why=$(is_idle_reason "$KID"); is_idle "$KID"; rc=$?
case "$why" in *"background work in flight"*"(1 task,"*"shell running: a build"*) [ "$rc" = 1 ] && ok "the watch and a shell: busy (is_idle: 1), the shell named" || bad "watch+shell: is_idle $rc";; *) bad "watch+shell: '$why'";; esac
stop_hook "{\"session_id\":\"$U1\",\"background_tasks\":[$(watch_task w1 "$WURL" "watch requested"),{\"id\":\"t\",\"type\":\"shell\",\"status\":\"running\",\"description\":\"a build\"}]}"
why=$(is_idle_reason "$KID"); is_idle "$KID"; rc=$?
case "$why" in *"(1 task,"*"shell running: a build"*"(and 1 artifact watch, not counted)"*) [ "$rc" = 1 ] && ok "a requested watch and a shell: busy, the shell named, the watch not counted" || bad "requested+shell: is_idle $rc";; *) bad "requested+shell: '$why'";; esac
stop_hook "{\"session_id\":\"$U1\",\"background_tasks\":[{\"id\":\"m\",\"type\":\"monitor\",\"status\":\"running\",\"description\":\"live updates for artifact $WURL (watch started)\"},{\"id\":\"s\",\"type\":\"shell\",\"status\":\"running\",\"description\":\"live updates for artifact $WURL (watch requested)\"}]}"
is_idle "$KID"; [ $? = 1 ] && [ -z "$(busy_watches "$KID" "$U1")" ] && ok "an unknown label on a monitor, a real label on a shell: both work in flight" || bad "near misses read idle: '$(is_idle_reason "$KID")'"
for d in "live updates for artifact $WURL (watch requested) and a build" "live updates for artifact $WURL (watch requested; auto-replies)" "live updates for artifact $WURL (Watch requested)" "live updates for artifact $WURL (watch requested)(resume requested)"; do
    stop_hook "{\"session_id\":\"$U1\",\"background_tasks\":[{\"id\":\"m\",\"type\":\"monitor\",\"status\":\"running\",\"description\":\"$d\"}]}"
    is_idle "$KID"; [ $? = 1 ] && [ -z "$(busy_watches "$KID" "$U1")" ] || bad "near miss read idle: '$d'"
done
is_idle "$KID"; [ $? = 1 ] && ok "near misses (more words, a cut-off label, another case, two labels): work in flight" || bad "the last near miss read idle"

echo "== an empty record: idle, although the process has a child; the stale record falls back to the guesses; parked still wins"
stop_hook "{\"session_id\":\"$U1\",\"background_tasks\":[],\"session_crons\":[]}"
[ "$(rec "$U1" tasks)" = 0 ] && [ -z "$(is_idle_reason "$KID")" ] && ok "nothing in flight → idle, child pid $(pgrep -P "$KID" | head -1) or not" || bad "empty record: tasks=$(rec "$U1" tasks), why='$(is_idle_reason "$KID")'"
is_idle "$KID" && ok "is_idle: 0" || bad "is_idle rc=$? on an empty record"
S2=$(( S1 + 5000 )); row "$KID" "$U1" idle "$S2"      # the registry flipped since (a turn ended without the hook)
why=$(is_idle_reason "$KID"); case "$why" in "a background task is running (child pids: "*) ok "the registry flipped since: back to the child-pid guess — '$why'";; *) bad "stale record: '$why'";; esac
is_idle "$KID"; [ $? = 1 ] && ok "is_idle: 1 (the guess)" || bad "is_idle stale"
busy_state "$KID" "$U1" >/dev/null; [ $? = 2 ] && ok "busy_state: 2 (no record for this stretch)" || bad "busy_state rc=$?"
# a plugin's MCP server under claude (CLAUDE_PLUGIN_ROOT in its environment, no shell-snapshot) runs for the session's
# life: the guess must not read it as work (a recycle once skipped many panes over such a server), while a
# plain child beside it still counts and is the only one named
U9=99999999-0000-4000-8000-000000000009
bash -c 'CLAUDE_PLUGIN_ROOT=/plugins/pdf sleep 900 & wait' & MKID=$!; sleep 0.5; row "$MKID" "$U9" idle "$(ms_ago 60)"
[ -z "$(is_idle_reason "$MKID")" ] && ok "only a plugin's MCP server under claude: idle by the guess" || bad "MCP child read busy: '$(is_idle_reason "$MKID")'"
is_idle "$MKID" && ok "is_idle: 0 with only an MCP server child" || bad "is_idle rc=$? with only an MCP child"
bash -c 'CLAUDE_PLUGIN_ROOT=/plugins/pdf sleep 900 & sleep 900 & wait' & BKID=$!; sleep 0.5; row "$BKID" "$U9" idle "$(ms_ago 60)"
plain=$(for k in $(pgrep -P "$BKID"); do grep -qs CLAUDE_PLUGIN_ROOT "/proc/$k/environ" || echo "$k"; done)
why=$(is_idle_reason "$BKID"); case "$why" in "a background task is running (child pids: $plain); running under it: pid $plain, "*) mixed=1;; *) mixed=0;; esac   # the holder named after the pids
[ "$mixed" = 1 ] && ok "an MCP server and a plain child: busy, only the plain child named" || bad "mixed: '$why' (plain: $plain)"
is_idle "$BKID"; [ $? = 1 ] && ok "is_idle: 1 with a plain child beside the MCP server" || bad "is_idle mixed"
pkill -P "$MKID"; pkill -P "$BKID"; kill "$MKID" "$BKID" 2>/dev/null
row "$KID" "$U1" idle "$S2" fork-0001; stop_hook "{\"session_id\":\"$U1\",\"background_tasks\":[]}"
why=$(is_idle_reason "$KID"); case "$why" in "conversation parked to a background fork (fork-0001)"*) ok "a parked fork wins over an empty record";; *) bad "parked: '$why'";; esac
is_idle "$KID"; [ $? = 1 ] && ok "is_idle: 1 for the parked fork" || bad "is_idle parked"
row "$KID" "$U1" idle "$S2"
S2b=$(ms_ago 3); row "$KID" "$U1" idle "$S2b"; stop_hook "{\"session_id\":\"$U1\",\"background_tasks\":[]}"
why=$(is_idle_reason "$KID"); case "$why" in "idle for only "*) ok "the 10 s settle still comes first: '$why'";; *) bad "settle: '$why'";; esac

echo "== payloads the hook must survive: no background_tasks field, malformed JSON, empty stdin, no session id, a path as the id"
rm -f "$BUSY/$U1"
stop_hook "{\"session_id\":\"$U1\",\"hook_event_name\":\"Stop\"}"; rc=$?
[ "$rc" = 0 ] && [ ! -e "$BUSY/$U1" ] && ok "no background_tasks: exit 0, no record (the guesses apply)" || bad "missing field: rc=$rc, record=$([ -e "$BUSY/$U1" ] && echo yes || echo no)"
stop_hook "{\"session_id\": \"$U1\", \"background_tasks\": ["; rc=$?; [ "$rc" = 0 ] && [ ! -e "$BUSY/$U1" ] && ok "malformed JSON: exit 0, no record" || bad "malformed: rc=$rc"
stop_hook ''; rc=$?; [ "$rc" = 0 ] && ok "empty stdin: exit 0" || bad "empty stdin: rc=$rc"
stop_hook '{"background_tasks": []}'; rc=$?; [ "$rc" = 0 ] && [ -z "$(ls -A "$BUSY" 2>/dev/null)" ] && ok "no session_id: exit 0, nothing written" || bad "no sid: rc=$rc, $(ls -A "$BUSY" 2>/dev/null)"
stop_hook '{"session_id":"../escaped","background_tasks":[]}'; [ ! -e "$SALA_STATE_DIR/escaped" ] && [ -z "$(ls -A "$BUSY" 2>/dev/null)" ] && ok "a path as session_id: refused" || bad "path escape"
stop_hook "{\"session_id\":\"$U2\",\"background_tasks\":[]}"; [ "$(rec "$U2" tasks)" = 0 ] && [ -z "$(rec "$U2" seen)" ] && [ -z "$(rec "$U2" flip)" ] && ok "a session with no registry row: a record with no stamp (never trusted)" || bad "no row: $(slurp "$BUSY/$U2")"

echo "== the flip after the hooks: the record is stamped by the detached waiter once the row goes idle"
S3=$(ms_ago 90); row "$KID" "$U1" busy "$S3"
stop_hook "{\"session_id\":\"$U1\",\"background_tasks\":[]}"
[ -e "$BUSY/$U1" ] && [ -z "$(rec "$U1" flip)" ] && [ "$(rec "$U1" seen_status)" = busy ] && [ "$(rec "$U1" seen)" = "$S3" ] && ok "written at once, unstamped (the row said busy, stamped $S3)" || bad "unstamped record: $(slurp "$BUSY/$U1")"
why=$(is_idle_reason "$KID"); case "$why" in "registry says 'busy'"*) ok "meanwhile the registry's busy holds";; *) bad "busy row: '$why'";; esac
S4=$(( S3 + 3000 )); row "$KID" "$U1" idle "$S4"
waitfor '[ "$(rec "$U1" flip)" = "$S4" ]' 40 && ok "stamped with the idle flip within seconds of it" || bad "not stamped: $(<"$BUSY/$U1")"
busy_hook_idle "$KID" "$U1" && [ -z "$(is_idle_reason "$KID")" ] && ok "busy_hook_idle: nothing in flight for this stretch → idle" || bad "busy_hook_idle: $(busy_state "$KID" "$U1"; echo rc=$?)"
row "$KID" "$U1" busy "$S4"
stop_hook "{\"session_id\":\"$U1\",\"background_tasks\":[]}"; stop_hook "{\"session_id\":\"$U1\",\"background_tasks\":[{\"id\":\"x\",\"type\":\"shell\",\"status\":\"running\",\"description\":\"later\"}]}"
S5=$(( S4 + 3000 )); row "$KID" "$U1" idle "$S5"
waitfor '[ "$(rec "$U1" flip)" = "$S5" ]' 40 && [ "$(rec "$U1" tasks)" = 1 ] && ok "two waiters on two records: the newer record (tasks=1) is the one stamped" || bad "two waiters: $(<"$BUSY/$U1")"
row "$KID" "$U1" busy "$S5"; rm -f "$BUSY/$U1"; stop_hook "{\"session_id\":\"$U1\",\"background_tasks\":[]}"; rm -f "$HOME/.claude/sessions/$KID.json"   # the process gone: the waiter gives up
sleep 1.5; [ -z "$(rec "$U1" flip)" ] && [ -z "$(pgrep -f "hook stamp $U1" 2>/dev/null)" ] && ok "the row gone (an /exit right after the turn): the waiter leaves the record unstamped and exits" || bad "without a row: flip='$(rec "$U1" flip)' waiters='$(pgrep -af "hook stamp $U1")'"
row "$KID" "$U1" idle "$S5"

echo "== hook post-tool: silent without a flag (stdin untouched), the relaunch notice once per relaunch with one"
rm -rf "$WAITD"
out=$("$SALA" hook post-tool < /dev/null); rc=$?; [ "$rc" = 0 ] && [ -z "$out" ] && ok "no flag anywhere: exit 0, silent" || bad "no flag: rc=$rc out='$out'"
out=$( { sleep 5; echo '{"session_id":"never-read"}'; } | "$SALA" hook post-tool & p=$!; sleep 1; kill -0 $p 2>/dev/null && echo still-waiting; wait $p ); [ -z "$out" ] && ok "no flag: it does not read stdin (gone before a slow writer wrote)" || bad "no flag read stdin: $out"
waiting_raise "$U1" recycle set-1 $$
out=$(post_hook "{\"session_id\":\"$U1\",\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{},\"tool_response\":{}}")
python3 -c 'import json, sys; h = json.loads(sys.argv[1])["hookSpecificOutput"]; sys.exit(0 if h["hookEventName"] == "PostToolUse" and h["additionalContext"] == sys.argv[2] else 1)' "$out" "${LINE//<what>/recycle}" \
    && ok "flag up: PostToolUse JSON, additionalContext = the relaunch notice for a recycle" || bad "post-tool output: $out"
out=$(post_hook "{\"session_id\":\"$U1\"}"); [ -z "$out" ] && ok "the next tool call: told already, silent" || bad "told twice: $out"
out=$(post_hook "{\"session_id\":\"$U2\"}"); [ -z "$out" ] && ok "another session: silent" || bad "the wrong session was told: $out"
waiting_raise "$U1" recycle set-1 $$; out=$(post_hook "{\"session_id\":\"$U1\"}"); [ -z "$out" ] && ok "raised again for the same relaunch: still told" || bad "same set told again"
waiting_raise "$U1" update set-2 $$; out=$(post_hook "{\"session_id\":\"$U1\"}")
grep -q '"additionalContext": "\[sala\] ' <<< "$out" && ok "a new relaunch tells it again" || bad "new set: $out"
waiting_clear "$U1"; out=$(post_hook "{\"session_id\":\"$U1\"}"); [ -z "$out" ] && [ ! -e "$WAITD/$U1.told" ] && ok "cleared: silent, the told marker gone" || bad "after clear: '$out' $(ls "$WAITD")"
waiting_raise "$U2" auto set-3 4194303; waiting_raise "$U3" auto set-3 $$; waiting_told "$U3"; : > "$WAITD/$U1.told"
waiting_prune
[ ! -e "$WAITD/$U2" ] && [ -e "$WAITD/$U3" ] && [ -e "$WAITD/$U3.told" ] && [ ! -e "$WAITD/$U1.told" ] && ok "prune: a dead owner's flag and an orphan told marker go, a live owner's flag stays" || bad "prune: $(ls "$WAITD")"
waiting_clear_owner $$; [ -z "$(ls -A "$WAITD")" ] && ok "clear_owner: every flag of this owner" || bad "clear_owner: $(ls "$WAITD")"
waiting_raise "$U2" auto set-4 $$; waiting_clear_all; [ -z "$(ls -A "$WAITD")" ] && ok "clear_all (a new recycle)" || bad "clear_all"
pkill -P "$KID" 2>/dev/null; kill "$KID" 2>/dev/null; KID=""; rm -f "$HOME/.claude/sessions/"*.json

# ── the ready path end to end: a retry worker, the flag, the Stop hook's empty record, the relaunch ──
# exit-empty off once a session has started the server: ready_path ends by killing its only session, and the next new-session must
# not race the server going away (the same failure as tests/sets-master.sh). cleanup kills it.
mk() { local n="$1" u="$2"; $T new-session -d -s "sala-test-$n" -c "$HOME" -e FAKE_SESSION_ID="$u" -e FAKE_NAME="$n" -e FAKE_LOG="$FAKE_LOG"; $T set -s exit-empty off; $T send-keys -t "sala-test-$n" 'claude' Enter; }
ready_path() {  # <pane name> <uuid>
    local n="$1" u="$2" c p n0 out
    mk "$n" "$u"; waitfor '[ -n "$(cpid '"$n"')" ] && [ -r "$HOME/.claude/sessions/$(cpid '"$n"').json" ]' 40 || { bad "the fake pane sala-test-$n did not start"; return; }
    c=$(cpid "$n"); p=$(tmux display -p -t "sala-test-$n" '#{pane_id}')
    stop_hook "{\"session_id\":\"$u\",\"background_tasks\":[{\"id\":\"t\",\"type\":\"shell\",\"status\":\"running\",\"description\":\"a long test\"}]}"
    out=$(is_idle_reason "$c"); case "$out" in *"background work in flight"*"shell running: a long test"*) ok "sala-test-$n reads busy by its record";; *) bad "pane: '$out'";; esac
    export SALA_RETRY_EVERY=600 SALA_RETRY_WINDOW=900   # the next tick is 10 min away: only a wake relaunches it in time
    setsid "$SALA" revive --retry-worker --force -- "$p|sala-test-$n|sala-test-$n:0|$c" </dev/null >>"$RLOG" 2>&1 &
    waitfor '[ -e "$WAITD/'"$u"'" ]' 30 && ok "the worker raised the flag (kind $(flag "$u" kind), set $(flag "$u" set), owner alive: $(kill -0 "$(flag "$u" owner)" 2>/dev/null && echo yes || echo no))" || { bad "no flag: $(ls "$WAITD" 2>/dev/null); $(tail -3 "$RLOG")"; return; }
    out=$(post_hook "{\"session_id\":\"$u\"}"); grep -q '"additionalContext": "\[sala\] ' <<< "$out" && ok "its next tool call gets the line, once" || bad "post-tool: $out"
    out=$(post_hook "{\"session_id\":\"$u\"}"); [ -z "$out" ] && ok "and the one after is silent" || bad "told twice: $out"
    sleep 3; [ "$(grep -c "^start $u" "$FAKE_LOG")" = 1 ] && ok "not relaunched while its record says busy" || bad "relaunched although busy"
    n0=$(grep -c "^start $u" "$FAKE_LOG")
    stop_hook "{\"session_id\":\"$u\",\"background_tasks\":[],\"session_crons\":[]}"   # the turn ended with nothing in flight
    waitfor '[ "$(grep -c "^start '"$u"'" "$FAKE_LOG")" -gt '"$n0"' ]' 180 && ok "relaunched within $(( $(date +%s) - $(stat -c %Y "$BUSY/$u") )) s of that record (the tick was 10 min away)" || bad "not relaunched: $(tail -8 "$RLOG")"
    waitfor '[ ! -e "$WAITD/'"$u"'" ] && [ ! -e "$WAITD/'"$u"'.told" ]' 40 && ok "the flag is down after the relaunch" || bad "flag left: $(ls "$WAITD")"
    waitfor '[ "$(workers)" = 0 ]' 60 && ok "the worker finished: $(grep 'retry: finished' "$RLOG" | tail -1 | sed 's/.*retry: //')" || bad "a worker is still running"
    $T kill-session -t "sala-test-$n" 2>/dev/null; : > "$POSTS"; : > "$RLOG"
}
echo "== the ready path, a recycle: the Stop hook's empty record wakes the retry worker, which relaunches the pane at once"
ready_path r "$(uuid 21)"   # (the same run for SALA_RELAUNCH_KIND=update was dropped: the kind changes only the words)

echo "== the auto-armed artifact watch: a pane holding only it is relaunched as it is, nothing sent to the session; beside a shell it is left"
SLOG="$HOME/sock.log"; : > "$SLOG"
mkw() { $T new-session -d -s "sala-test-$1" -c "$HOME" -e FAKE_SESSION_ID="$2" -e FAKE_NAME="$1" -e FAKE_LOG="$FAKE_LOG" -e FAKE_SOCK_LOG="$SLOG"; $T set -s exit-empty off; $T send-keys -t "sala-test-$1" 'claude' Enter; }
UW=$(uuid 31); UB=$(uuid 32)
mkw w "$UW"; mkw b "$UB"; fake_up w b || bad "the fake panes did not start"
CW=$(cpid w); CB=$(cpid b)
stop_hook "{\"session_id\":\"$UW\",\"background_tasks\":[$(watch_task w1)]}"
stop_hook "{\"session_id\":\"$UB\",\"background_tasks\":[$(watch_task w1),{\"id\":\"t\",\"type\":\"shell\",\"status\":\"running\",\"description\":\"tail logs\"}]}"
out=$(SALA_RETRY_WORKER=1 "$SALA" revive --only sala-test-w --force 2>&1)
NW=$(cpid w)
[ -n "$NW" ] && [ "$NW" != "$CW" ] && [ "$(grep -c "^start $UW" "$FAKE_LOG")" = 2 ] && ok "only the watch: relaunched (pid $CW → $NW)" || bad "watch-only pane not relaunched: $out"
# the watch is left to the CLI, which arms it again on the resume (a watch the session itself stops comes back only on
# The owner's own message): nothing reaches the resumed session's inbox, and the sweep says nothing of the watch
sleep 2
[ -z "$(grep "^$UW " "$SLOG")" ] && ! grep -qi 'artifact' <<< "$out" && ok "the resumed session got no message, the sweep names no watch" || bad "after the relaunch: msgs='$(grep "^$UW " "$SLOG")' out='$(grep -i artifact <<< "$out")'"
out=$(SALA_RETRY_WORKER=1 "$SALA" revive --only sala-test-b --force 2>&1)
[ "$(cpid b)" = "$CB" ] && [ "$(grep -c "^start $UB" "$FAKE_LOG")" = 1 ] && grep -q "sala-test-b:0: background work in flight" <<< "$out" && [ -z "$(grep "^$UB " "$SLOG")" ] \
    && ok "the watch and a shell: left alone (busy, not relaunched, no message)" || bad "watch+shell pane: $out"
$T kill-session -t sala-test-w 2>/dev/null; $T kill-session -t sala-test-b 2>/dev/null

echo; [ "$fail" = 0 ] && echo "busyhooks: pass" || echo "busyhooks: FAIL"
exit $fail
