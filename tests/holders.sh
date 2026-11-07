#!/usr/bin/env bash
# The holders (lib/holders.py, lib/common.sh holders_*, lib/ready.sh, lib/hook.sh `subagent-stop`).
# The case behind it: a session answered "stop your own background watches" with `sala ready` and
# "no background shell" while an `until ! pgrep -f "bash tests/run.sh"; do sleep 5; done` loop, started with run_in_background
# by one of its SUBAGENTS, held its relaunch for hours. Two parts, both against stand-ins for a claude (a bash with a
# registry row) and real child processes, no tmux server and no claude binary:
#  1. NAMING: the process tree under the registered process is read, never a name. The scan lists a Bash-tool shell (the
#     shell-snapshot form, the eval'd command pulled out, a quote inside it kept) with its pid, how long it ran, the task id
#     that its stdout file names and the subagent whose transcript received that id; a plugin's MCP server child is left out
#     (as work_children does); the caller's own chain (the shell that runs `sala ready`) is never listed; a command is cut to
#     120 characters and masked like every other post text. Nothing under the pane → "0" and `sala ready` / the relaunch
#     notice as before. `sala ready` says "but N background process(es) still run under this pane and will be cut / hold
#     the relaunch" with a line each, the relaunch notice carries the same list, the skip reasons name the pids.
#  2. THE SubagentStop HOOK: stops the shell a subagent that handed back left running, and every process it started: its task id (named by /proc/<pid>/fd/1)
#     is one the subagent's own transcript received, the process is under the registered claude and carries the command text.
#     It also stops a process that left the shell's tree (its parent died) but keeps the task's output file on fd 1 / 2, and none
#     whose fd names another task's file, or the same id in another scratch directory.
#     The main thread's task (listed too), a process outside the claude's tree, a subagent that has not handed back, a command
#     text that does not match, SALA_SUBAGENT_CLEANUP=off and garbage input: nothing is stopped, exit 0, nothing on stdout.
# Isolated HOME. Usage: bash tests/holders.sh   (exit 0 = pass; ~25 s)
# Checks that only read text use the shell's own builtins: the helpers after the row() function below.
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_SET SALA_SET_SELF SALA_RECYCLE SALA_RETRY_WORKER SALA_RELAUNCH_KIND SALA_RELAUNCH_WAITING_TEXT SALA_SUBAGENT_CLEANUP
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/tasks" "$HOME/.local/share/tmux/resurrect"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_LOG_DIR="$HOME/.claude"
SALA="$ROOT/bin/salamander"; PY="$ROOT/lib/holders.py"; SLOG="$HOME/.claude/salamander-subagent.log"
PIDS=(); FP=""
killtree() { local k; _children_r k "$2"; [ -z "$k" ] || kill "$1" $k 2>/dev/null; kill "$1" "$2" 2>/dev/null; true; }   # <signal> <pid> → its children, then it (no pkill)
cleanup() { local p; for p in ${PIDS[@]+"${PIDS[@]}"}; do killtree -TERM "$p"; done; nap 0.3
    for p in ${PIDS[@]+"${PIDS[@]}"}; do killtree -KILL "$p"; done; rm -rf "${HOME:?}" 2>/dev/null; true; }
trap cleanup EXIT
. "$ROOT/lib/common.sh"
U1=$(uuid 1); U2=$(uuid 2); U3=$(uuid 3)
row() { local now; printf -v now '%(%s)T' -1; printf '{"pid":%s,"sessionId":"%s","name":"t","status":"%s","statusUpdatedAt":%s,"version":"9.9.9"}\n' "$1" "$2" "$3" "$(( (now - 60) * 1000 ))" > "$HOME/.claude/sessions/$1.json"; }
first() { printf '%s' "${1%%$'\n'*}"; }                                                  # <text> → its first line
nlines() { local n=0 l; [ -n "$1" ] || { echo 0; return; }; while IFS= read -r l || [ -n "$l" ]; do n=$((n + 1)); done <<< "$1"; echo "$n"; }   # <text> → how many lines
line_n() { local -a a; mapfile -t a <<< "$1"; printf '%s' "${a[$(($2 - 1))]-}"; }         # <text> <n> → the n-th line
hasline() { local l; while IFS= read -r l || [ -n "$l" ]; do [[ $l =~ $2 ]] && return 0; done <<< "$1"; return 1; }   # <text> <ERE> → 0 when a line matches (grep -qE)
count_re() { local t=$1 n=0; while [[ $t =~ $2 ]]; do n=$((n + 1)); t=${t#*"${BASH_REMATCH[0]}"}; done; echo "$n"; }   # <text> <ERE> → how many matches (grep -o | wc -l)
jstr() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }                       # <text> → a JSON string (no control characters in these texts)
scan() { SALA_SCRUB_PY="$SALA_SCRUB_PY" python3 -I -S "$PY" scan "$@"; }
# a claude stand-in: a bash running $1 (its job), registered under $2 once started; its pid is left in FP
fake() { bash -c "$1" & FP=$!; PIDS+=("$FP"); row "$FP" "$2" "${3:-idle}"; nap 0.4; }
# the Bash-tool shell as the CLI starts it (2.1.310), as a line for a stand-in: the argv (snapshot prefix, eval of the quoted
# command, the cwd file) is exported as CMD_<task id> so that no shell parses it twice; stdout and stderr on the task's output
# file. $1 task id, $2 the command (a single quote in it escaped as the CLI does: '"'"')
defcmd() { local q=${2//\'/\'\"\'\"\'}; export "CMD_$1=source $HOME/shell-snapshots/s.sh 2>/dev/null || true && shopt -u extglob 2>/dev/null || true && eval '$q' < /dev/null && pwd -P >| $HOME/cwd-$1"; }   # <task id> <command>
shellcmd() { echo "bash -c \"\$CMD_$1\" > $HOME/tasks/$1.output 2>&1 &"; }   # <task id> → the stand-in's line that starts it (after defcmd, in this shell)

echo "== the scan: a shell a subagent started, the main thread's own, a plugin's MCP server, the cut"
mkdir -p "$HOME/.claude/projects/x/$U1/subagents"
SUB="$HOME/.claude/projects/x/$U1/subagents/agent-aa11bb22cc.jsonl"
LOOP='until ! pgrep -f "bash tests/run.sh"; do sleep 5; done'     # the incident's: it matches itself, so it never ends
printf '%s\n' "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"tu1\",\"content\":\"Command running in background with ID: taskloop1. Output is being written to: x\"}]}}" > "$SUB"
printf -v LONG '%200s' ''; LONG="echo ${LONG// /x}; sleep 905"
defcmd taskloop1 "$LOOP"; defcmd taskmain2 'echo "it'"'"'s mine"; sleep 903'; defcmd tasklong3 "$LONG"; defcmd taskleak4 'token=abc123SECRETvalue sleep 906'
fake "$(shellcmd taskloop1)
$(shellcmd taskmain2)
$(shellcmd tasklong3)
CLAUDE_PLUGIN_ROOT=/plugins/pdf sleep 904 &
wait" "$U1"; K=$FP
waitfor '[ "$(first "$(scan "$K")")" = 3 ]' 20 || bad "scan count: $(scan "$K")"
out=$(scan "$K")
[ "$(first "$out")" = 3 ] && ok "three holders: the three shells; the plugin's MCP server (CLAUDE_PLUGIN_ROOT) left out" || bad "count: $out"
hasline "$out" '^pid [0-9]+, up [0-9]+ s, task taskloop1, started by a subagent \(aa11bb22\): until ! pgrep -f "bash tests/run.sh"; do sleep 5; done$' && ok "the loop: pid, up, task id from its output file, the subagent from that id in its transcript, the command without the snapshot prefix" || bad "loop line: $out"
hasline "$out" "^pid [0-9]+, up [0-9]+ s, task taskmain2: echo \"it's mine\"; sleep 903\$" && ok "the main thread's shell: no subagent named; a quote in the command kept" || bad "main line: $out"
l=""; while IFS= read -r x; do [[ $x == *"task tasklong3"* ]] && l=${x#*: }; done <<< "$out"; [ "${#l}" = 120 ] && [ "${l: -1}" = "…" ] && ok "a long command cut to 120 characters" || bad "cut: ${#l} '$l'"
m=$(scan "$K" --max 1); [ "$(nlines "$m")" = 3 ] && [ "$(line_n "$m" 3)" = 'and 2 more' ] && ok "--max 1: one line and 'and 2 more'" || bad "--max: $m"
fake "$(shellcmd taskleak4)
wait" "$U2"; K2=$FP
waitfor '[ "$(first "$(scan "$K2")")" = 1 ]' 20; out=$(scan "$K2")
has "$out" 'abc123SECRETvalue' && bad "a secret-shaped value came through: $out" || { has "$out" 'token=…' && ok "a token=value in a command is masked like any post text" || bad "masking: $out"; }

echo "== the caller's own chain and an empty pane"
fake "sleep 907 & bash -c 'python3 -I -S $PY scan \$PPID > $HOME/scan3.txt'; wait" "$U2"
waitfor '[ -s "$HOME/scan3.txt" ]' 20
s3=$(slurp "$HOME/scan3.txt"); [ "$(first "$s3")" = 1 ] && has "$s3" 'sleep 907' && ok "scan run from a child of the pane: that child (the Bash call that ran it) is not a holder, the sleep beside it is" || bad "own chain: $s3"
fake "wait" "$U2"; K4=$FP
[ "$(scan "$K4")" = 0 ] && ok "nothing under the pane: '0' alone" || bad "empty: $(scan "$K4")"
[ "$(scan 999999)" = 0 ] && ok "a pid that is no pane: '0'" || bad "no pane: $(scan 999999)"
[ "$(python3 -I -S "$PY" scan abc 2>/dev/null)" = 0 ] && ok "garbage argument: '0', no traceback" || bad "garbage: $(python3 -I -S "$PY" scan abc 2>&1)"

echo "== sala ready names them; the notice carries them; the skip reasons name the pids"
fake "sleep 908 & \"$SALA\" ready > $HOME/ready5.txt 2>&1; wait" "$U3"; K5=$FP
waitfor '[[ $(slurp "$HOME/ready5.txt") == *"no recycle is waiting right now"* ]]' 20
r=$(slurp "$HOME/ready5.txt"); mapfile -t RL <<< "$r"
[ "${RL[0]}" = "ready: t ($U3) — but 1 background process(es) still run under this pane and will be cut at the relaunch, or hold it:" ] \
    && hasline "${RL[1]}" '^  pid [0-9]+, up [0-9]+ s: sleep 908$' && hasline "${RL[2]}" '^Stop them first if they are not needed: TaskStop <task id>.*`kill <pid>`\.$' \
    && [[ ${RL[-1]} == "ready: t ($U3) — no recycle is waiting right now"* ]] && ok "sala ready: the holder block first (the count, pid, up, command, how to stop), the usual line after it" || bad "ready: $r"
fake "\"$SALA\" ready > $HOME/ready6.txt 2>&1; wait" "$U2"
waitfor '[[ $(slurp "$HOME/ready6.txt") == *"no recycle is waiting right now"* ]]' 20; r=$(slurp "$HOME/ready6.txt")
[ "$(nlines "$r")" = 1 ] && [[ $r == "ready: t ($U2) — no recycle is waiting right now"* ]] && ok "nothing under the pane: sala ready's output is the one line it always was" || bad "ready, none: $r"
t0=$SECONDS; scan "$K" >/dev/null; [ $(( SECONDS - t0 )) -lt 5 ] && ok "the scan is fast (under 5 s; ~100 ms on an idle box, the bound allows for 45 suites at once)" || bad "slow scan: $(( SECONDS - t0 )) s"
LINE='[sala] A <what> is waiting for this session. Bring your work to a checkpoint. Stop your own background watches (TaskStop) and put what they were waiting for in a `sala note "<step>"` before `sala ready`. If a step must wait until after the relaunch, leave it with `sala note "<step>"` (or set the board item'\''s recycle flag), then run `sala ready` as the turn'\''s last call.'
n=$(relaunch_text recycle "$K"); n0=$(relaunch_text recycle)
[ "$n0" = "${LINE//<what>/recycle}" ] && ok "the notice without a pid: the line, as before" || bad "notice, no pid: $n0"
[ "$(relaunch_text recycle "$K4")" = "$n0" ] && ok "the notice for a pane with nothing under it: the line alone" || bad "notice, empty pane"
[ "$(first "$n")" = "$(first "$n0")" ] && hasline "$n" '^Still running under this pane right now, 3 background process\(es\) that the relaunch will cut or that hold it:$' && has "$n" 'task taskloop1, started by a subagent' && ok "the notice with the pid: the line, then the holders" || bad "notice: $n"
row "$K" "$U1" shell
why=$(is_idle_reason "$K"); case "$why" in "registry says 'shell' (background shells or tasks hold the pane); running under it: pid "*"task taskloop1, started by a subagent (aa11bb22)"*) ok "registry 'shell': the reason keeps its 'registry says' head (transient), no longer says a turn or a dialog runs, and names the holders";; *) bad "shell reason: $why";; esac
row "$K" "$U1" idle
row "$K5" "$U3" idle; rm -f "${SALA_READY_DIR:?}/${U3:?}"; why=$(is_idle_reason "$K5")
case "$why" in "a background task is running (child pids: "*"); running under it: pid "*"sleep 908") ok "a child process: 'a background task is running (child pids: …)' kept, the holders after it";; *) bad "child reason: $why";; esac

echo "== the deferred-pane bullet: one short reason, no pid, task id or command"
# the posts word a held pane in one of two ways (common.sh, hold_bullet); what is parsed (transient_skip) still reads the long reason above
[ "$(hold_age_words 0)" = "1 min" ] && [ "$(hold_age_words 59)" = "1 min" ] && [ "$(hold_age_words 2100)" = "35 min" ] && [ "$(hold_age_words 3599)" = "59 min" ] \
    && [ "$(hold_age_words 3600)" = "1 h" ] && [ "$(hold_age_words 7300)" = "2 h" ] && [ "$(hold_age_words 86399)" = "23 h" ] && [ "$(hold_age_words 86400)" = "1 day" ] && [ "$(hold_age_words 200000)" = "2 days" ] \
    && ok "the age in short words: 35 min, 2 h, 1 day (rounded down, never below 1 min)" || bad "age words: $(hold_age_words 0) $(hold_age_words 2100) $(hold_age_words 7300) $(hold_age_words 200000)"
row "$K" "$U1" shell
b=$(hold_bullet sala-x "$K" "$(is_idle_reason "$K")")
[ "$b" = "sala-x: its 3 background tasks ran for 1 min; sala relaunches it once they finish" ] && ok "registry 'shell' with three holders: \"its 3 background tasks ran for <age>; sala relaunches it once they finish\"" || bad "shell bullet: $b"
case "$b" in *pid*|*taskloop1*|*pgrep*|*sleep*|*until*|*registry*|*aa11bb22*) bad "the bullet carries a pid, task id, subagent id, command or 'registry': $b";; *) ok "no pid, task id, subagent id, command or 'registry' in the bullet";; esac
row "$K5" "$U3" shell
b=$(hold_bullet sala-y "$K5" "registry says 'shell' (background shells or tasks hold the pane); running under it: pid 1, up 5 h: sleep 908")
[ "$b" = "sala-y: its 1 background task ran for 1 min; sala relaunches it once they finish" ] && ok "one holder: \"its 1 background task ran for …\" (singular), the raw reason's pid and command never copied" || bad "one-holder bullet: $b"
row "$K5" "$U3" idle; rm -f "${SALA_READY_DIR:?}/${U3:?}"
b=$(hold_bullet sala-y "$K5" "$(is_idle_reason "$K5")")
[ "$b" = "sala-y: its 1 background task ran for 1 min; sala relaunches it once they finish" ] && ok "a child process under an idle pane (\"a background task is running (child pids: …)\") is the same kind" || bad "child bullet: $b"
row "$K4" "$U2" busy
b=$(hold_bullet sala-z "$K4" "registry says 'busy' (a turn or a dialog is running)")
[ "$b" = "sala-z: busy for 1 min; sala relaunches it once it is free" ] && ok "registry 'busy': \"busy for <age>; sala relaunches it once it is free\" (the age is the time since the status changed)" || bad "busy bullet: $b"
b=$(hold_bullet sala-z "$K4" "a turn is running (it started after the idle check) — /exit not sent, left on 9.9.9")
[ "$b" = "sala-z: busy for 1 min; sala relaunches it once it is free" ] && ok "\"a turn is running\" (the /exit refusal) is the busy kind too" || bad "turn bullet: $b"
row "$K4" "$U2" shell
b=$(hold_bullet sala-z "$K4" "registry says 'shell' (background shells or tasks hold the pane)")
[ "$b" = "sala-z: busy for 1 min; sala relaunches it once it is free" ] && ok "'shell' with no process to count (a stale row): the busy wording, never \"its 0 background tasks\"" || bad "stale shell bullet: $b"
for r in "unsubmitted text at the prompt (\"half a thought\") — typing /exit would append" "a terminal prompt is showing — dismiss it" "idle for only 3s (a just-queued turn may not have flipped the registry yet)" "parked in background job abcd1234: registry says 'busy' (a turn or a dialog is running)"; do
    hold_bullet sala-q "$K4" "$r" >/dev/null && bad "worded as a held pane: $r"
done; ok "a draft, a prompt, an idle-settle wait and a parked pane are neither kind: left to the caller's own wording (return 1)"
hold_bullet sala-q 999999 "registry says 'busy' (a turn or a dialog is running)" > "$HOME/hb.txt"
[ "$(slurp "$HOME/hb.txt")" = "sala-q: busy; sala relaunches it once it is free" ] && ok "a pid whose row cannot be read: the age is left out, the line still has both parts" || bad "no-row bullet: $(slurp "$HOME/hb.txt")"
sm=$(python3 -I -S "$PY" scan "$K" --summary); sm4=$(python3 -I -S "$PY" scan "$K4" --summary)
[[ $sm =~ ^3\ [0-9]+$ ]] && [ "$sm4" = "0 0" ] && [ "$(python3 -I -S "$PY" scan abc --summary 2>/dev/null)" = "0" ] && ok "scan --summary: '<n> <oldest secs>', '0 0' for an empty pane" || bad "summary: '$sm' / '$sm4'"
row "$K" "$U1" idle; row "$K4" "$U2" idle
H=$(holders_inline "$K"); [ "$(nlines "$H")" = 1 ] && [ "$(count_re "$H" 'pid [0-9]+,')" = 3 ] && ok "holders_inline: one line, three holders (' · ' between)" || bad "inline: $H"

echo "== the SubagentStop hook: only the shell that subagent started, only after it handed back"
SESS="$HOME/.claude/projects/x/$U2"; mkdir -p "$SESS/subagents"; AG=deadbeef0001; ATR="$SESS/subagents/agent-$AG.jsonl"
transcript() {  # <handback yes|no> <task id> <command text> → the subagent's transcript, as the CLI writes it
    {   printf '%s\n' "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"tu9\",\"name\":\"Bash\",\"input\":{\"command\":$(jstr "$3"),\"run_in_background\":true}}]}}"
        printf '%s\n' "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"tu9\",\"content\":\"Command running in background with ID: $2. Output is being written to: x\"}]}}"
        [ "$1" = yes ] && printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu10","name":"SubagentHandback","input":{"message":"done"}}]}}'
    } > "$ATR"; }
payload() {  # <task ids…> → the SubagentStop input: those tasks listed as running shells
    local t="" i; for i in "$@"; do t+="${t:+,}{\"id\":\"$i\",\"type\":\"shell\",\"status\":\"running\",\"description\":\"d\",\"command\":\"c\"}"; done
    printf '{"session_id":"%s","hook_event_name":"SubagentStop","agent_id":"%s","agent_type":"general-purpose","agent_transcript_path":"%s","stop_hook_active":false,"background_tasks":[%s],"session_crons":[]}' "$U2" "$AG" "$ATR" "$t"; }
alive() { local l; kill -0 "$1" 2>/dev/null || return 1; { read -r l < "/proc/$1/stat"; } 2>/dev/null || return 1; l=${l##*) }; [ "${l%% *}" != Z ]; }   # running, not a zombie
pidof_cmd() { local p k; _children_r k "$1"; for p in $k; do _nul_read "/proc/$p/cmdline"; [[ "${_NUL[*]-}" == *"$2"* ]] && { echo "$p"; return 0; }; done; return 0; }   # the first direct child of the stand-in whose command line has the text
mkclaude() {  # <jobs…> → a stand-in (pid in FP) running the jobs, then waiting for $HOME/go and running the hook with $HOME/hook-in.json
    fake "$1
exec {nf}<> <(:); until [ -e $HOME/go ]; do read -r -t 0.1 -u \$nf _; done 2>/dev/null
out=\$(\"$SALA\" hook subagent-stop < $HOME/hook-in.json 2>/dev/null); echo \"\$?|\$out\" > $HOME/hook-out.txt
wait" "$U2"; }
reset() { rm -f "$HOME/go" "$HOME/hook-out.txt" "$SLOG"; }
stop_claude() { killtree -TERM "$1"; }
GROUPED="setsid bash -c 'sleep 910; : subagent-job' > $HOME/tasks/tasksub1.output 2>&1 &"   # a group leader, as the CLI's shells are
PLAIN="bash -c 'sleep 911; : sub-plain-job' > $HOME/tasks/tasksub5.output 2>&1 &"           # no group of its own: the process and its children go one by one
MAIN="bash -c 'sleep 912; : main-job' > $HOME/tasks/taskmain2.output 2>&1 &"
setsid nohup bash -c 'sleep 913; : outside-job' > "$HOME/tasks/taskout3.output" 2>&1 < /dev/null & OUT=$!; PIDS+=("$OUT")   # started by the test, not under any stand-in
nap 0.3
transcript yes tasksub1 "sleep 910; : subagent-job"
printf '%s\n' "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"tu9\",\"content\":\"Command running in background with ID: taskout3. x\"}]}}" >> "$ATR"   # the subagent got that task id too, but its process is not under the pane
reset
mkclaude "$GROUPED
$PLAIN
$MAIN"; C=$FP
G=$(pidof_cmd "$C" subagent-job); M=$(pidof_cmd "$C" main-job); P=$(pidof_cmd "$C" sub-plain-job)
[ -n "$G" ] && [ -n "$M" ] && [ -n "$P" ] && [ "/proc/$G/fd/1" -ef "$HOME/tasks/tasksub1.output" ] && ok "setup: the subagent's shell, a plain one and the main thread's are children of the stand-in, each on its output file" || bad "setup: G=$G M=$M P=$P"
{ read -r l < "/proc/$G/stat"; l=${l##*) }; read -r _ _ pg _ <<< "$l"; [ "$pg" = "$G" ]; } && ok "(the subagent's shell leads its process group, as the CLI's do)" || bad "no group leader"
printf '%s' "$(payload tasksub1 taskmain2 taskout3)" > "$HOME/hook-in.json"; touch "$HOME/go"
waitfor '[ -s "$HOME/hook-out.txt" ]' 40
[ "$(slurp "$HOME/hook-out.txt")" = "0|" ] && ok "the hook: exit 0, nothing on stdout" || bad "hook out: $(slurp "$HOME/hook-out.txt")"
! alive "$G" && ok "the subagent's shell is stopped (its process group)" || bad "the subagent's shell still runs"
alive "$M" && ok "the main thread's own shell (listed as running too, not in the subagent's transcript) is untouched" || bad "the main thread's shell was stopped"
alive "$OUT" && ok "a process outside the stand-in's tree (its task id in the transcript and in the list) is untouched" || bad "the outside process was stopped"
alive "$P" && ok "a shell not named by the transcript (tasksub5) is untouched" || bad "plain shell stopped"
hasline "$(slurp "$SLOG")" "stopped task tasksub1, pid $G \(process group $G\).*SIGTERM.*sleep 910; : subagent-job" && ok "the log line: task, pid, group, command" || bad "log: $(slurp "$SLOG")"
has "$(slurp "$SLOG")" "taskout3" && has "$(slurp "$SLOG")" "no process under the pane writes to it" && ok "the outside task logged as not stopped, with the reason" || bad "log (outside): $(slurp "$SLOG")"
stop_claude "$C"

# without a group of its own: the process and everything it started, one by one
reset; transcript yes tasksub5 "sleep 911; : sub-plain-job"
mkclaude "$PLAIN
$MAIN"; C=$FP; P=$(pidof_cmd "$C" sub-plain-job); M=$(pidof_cmd "$C" main-job); _children_r PC "$P"; PC=${PC%% *}
printf '%s' "$(payload tasksub5 taskmain2)" > "$HOME/hook-in.json"; touch "$HOME/go"; waitfor '[ -s "$HOME/hook-out.txt" ]' 40
! alive "$P" && { [ -z "$PC" ] || ! alive "$PC"; } && alive "$M" && hasline "$(slurp "$SLOG")" "stopped task tasksub5, pid $P \(.*no group of its own" && ok "a shell without a group of its own: it and its child stopped, the main thread's untouched" || bad "plain: P alive=$(alive "$P" && echo y), PC=$PC, M alive=$(alive "$M" && echo y); $(slurp "$SLOG")"
stop_claude "$C"

# descendants: a loop that runs sleeps in process groups and sessions of their own, a subshell's grandchild, one that ignores SIGTERM
below_of() { local -a todo=("$1"); local out="" p k; while [ ${#todo[@]} -gt 0 ]; do p=${todo[0]}; todo=("${todo[@]:1}"); _children_r k "$p"; for p in $k; do out+=" $p"; todo+=("$p"); done; done; printf '%s' "${out# }"; }   # <pid> → all its descendants
pgrp_of() { local l; { read -r l < "/proc/$1/stat"; } 2>/dev/null; l=${l##*) }; set -- $l; echo "$3"; }   # <pid> → its process group
sess_of() { local l; { read -r l < "/proc/$1/stat"; } 2>/dev/null; l=${l##*) }; set -- $l; echo "$4"; }   # <pid> → its session
DESCMD="setsid bash -c ': desc-job; setsid sleep 920 & sleep 921 & ( setsid sleep 924; : ) & ( trap \"\" TERM; exec sleep 927 ) & until false; do sleep 922; done' > $HOME/tasks/tasksub6.output 2>&1 &"
DESCTXT=': desc-job; setsid sleep 920 & sleep 921 & ( setsid sleep 924; : ) & ( trap "" TERM; exec sleep 927 ) & until false; do sleep 922; done'
UNREL="sleep 925 &"
sleeps_below() { local n=0 p; for p in $(below_of "$1"); do _nul_read "/proc/$p/cmdline"; [[ "${_NUL[*]-}" =~ ^sleep\ (920|921|922|924|927)$ ]] && n=$((n + 1)); done; echo "$n"; }   # <pid> → how many of the five sleeps run below it
reset; transcript yes tasksub6 "$DESCTXT"
mkclaude "$DESCMD
$UNREL
$MAIN"; C=$FP; S=$(pidof_cmd "$C" desc-job); U=$(pidof_cmd "$C" "sleep 925"); M=$(pidof_cmd "$C" main-job)
waitfor '[ "$(sleeps_below "$S")" = 5 ]' 40
D=$(below_of "$S"); DN=$(count_re " $D" ' [0-9]+'); D920=; D924=; for p in $D; do _nul_read "/proc/$p/cmdline"; case "${_NUL[*]-}" in "sleep 920") D920=$p;; "sleep 924") D924=$p;; esac; done
[ -n "$S" ] && [ -n "$U" ] && [ "$(pgrp_of "$S")" = "$S" ] && [ -n "$D920" ] && [ -n "$D924" ] && [ "$(pgrp_of "$D920")" != "$S" ] && [ "$(sess_of "$D920")" != "$(sess_of "$S")" ] && [ "$(pgrp_of "$D924")" != "$S" ] && ok "setup: the shell leads its group; sleeps in groups and sessions of their own, a subshell's grandchild, a plain child and one that ignores SIGTERM run below it ($DN descendants)" || bad "desc setup: S=$S U=$U D920=$D920 D924=$D924 D=$D"
printf '%s' "$(payload tasksub6 taskmain2)" > "$HOME/hook-in.json"; touch "$HOME/go"; waitfor '[ -s "$HOME/hook-out.txt" ]' 40
gone=y; for p in $S $D; do ! alive "$p" || gone=$p; done
[ "$gone" = y ] && [ "$(slurp "$HOME/hook-out.txt")" = "0|" ] && ok "the shell and every descendant are gone (the sleep in its own session, the grandchild, the one that ignored SIGTERM too)" || bad "descendant still running: $gone ($(slurp "$HOME/hook-out.txt"))"
alive "$U" && alive "$M" && alive "$C" && ok "an unrelated sleep and the main thread's shell under the same claude, and the claude itself, are untouched" || bad "unrelated stopped: U=$(alive "$U" && echo y) M=$(alive "$M" && echo y) C=$(alive "$C" && echo y)"
L=$(slurp "$SLOG")
hasline "$L" "stopped task tasksub6, pid $S \\(process group $S\\).*SIGTERM to process group $S, $DN descendant\\(s\\), 0 outside its tree: " && [ "$(count_re "$L" "stopped task tasksub6, descendant pid [0-9]+ of $S, ")" = "$DN" ] && has "$L" "SIGKILL after 0.3 s" && ok "the log: the shell's line with the descendant count, one line per descendant, the SIGTERM-proof one marked SIGKILL" || bad "desc log: $L"
stop_claude "$C"; kill -KILL $D 2>/dev/null

# leftovers that left the shell's tree: their parent died (init or a subreaper has them now), but fd 1 / 2 still name the task's output file
mkdir -p "$HOME/scratch2/tasks"
ORPHTXT=": orphan-job; ( setsid sleep 301 & echo \$! > $HOME/orph1.pid ); ( trap \"\" TERM; setsid sleep 306 & echo \$! > $HOME/orph6.pid ); ( setsid sleep 303 > $HOME/tasks/taskoth8.output 2>&1 & echo \$! > $HOME/orph3.pid ); ( setsid sleep 305 > $HOME/scratch2/tasks/tasksub7.output 2>&1 & echo \$! > $HOME/orph5.pid ); ( setsid sleep 304 > /dev/null 2>&1 & echo \$! > $HOME/orph4.pid ); sleep 914; : orphan-end"
ORPHCMD="setsid bash -c '$ORPHTXT' > $HOME/tasks/tasksub7.output 2>&1 &"
reset; transcript yes tasksub7 "$ORPHTXT"
mkclaude "$ORPHCMD
$MAIN"; C=$FP; S=$(pidof_cmd "$C" orphan-job)
waitfor '[ -s "$HOME/orph1.pid" ] && [ -s "$HOME/orph6.pid" ] && [ -s "$HOME/orph3.pid" ] && [ -s "$HOME/orph5.pid" ] && [ -s "$HOME/orph4.pid" ]' 40
O1=$(slurp "$HOME/orph1.pid"); O6=$(slurp "$HOME/orph6.pid"); O3=$(slurp "$HOME/orph3.pid"); O5=$(slurp "$HOME/orph5.pid"); O4=$(slurp "$HOME/orph4.pid"); PIDS+=("$O1" "$O6" "$O3" "$O5" "$O4")
nap 0.3; B=" $(below_of "$C") "
okset=y; for p in $O1 $O6 $O3 $O5 $O4; do _nul_read "/proc/$p/cmdline"; [[ "${_NUL[*]-}" == "sleep 30"* ]] && [[ $B != *" $p "* ]] && [ "/proc/$p/fd/1" -ef "/proc/$p/fd/2" ] || okset=$p; done
[ "$okset" = y ] && [ -n "$S" ] && [ "/proc/$O1/fd/1" -ef "$HOME/tasks/tasksub7.output" ] && [ "/proc/$O3/fd/1" -ef "$HOME/tasks/taskoth8.output" ] && [ "/proc/$O5/fd/1" -ef "$HOME/scratch2/tasks/tasksub7.output" ] && ok "setup: five sleeps left the shell's tree (no longer below the stand-in); two write to the task's file, one to another task's, one to the same id in another scratch directory, one to /dev/null" || bad "orphan setup: $okset S=$S O1=$O1 O3=$O3 O5=$O5 B=$B"
printf '%s' "$(payload tasksub7)" > "$HOME/hook-in.json"; touch "$HOME/go"; waitfor '[ -s "$HOME/hook-out.txt" ]' 40
L=$(slurp "$SLOG")
! alive "$S" && ! alive "$O1" && ! alive "$O6" && [ "$(slurp "$HOME/hook-out.txt")" = "0|" ] && ok "the shell, the sleep outside its tree that writes to the task's file, and the one that ignores SIGTERM (SIGKILL) are gone" || bad "orphan: S=$(alive "$S" && echo y) O1=$(alive "$O1" && echo y) O6=$(alive "$O6" && echo y) out=$(slurp "$HOME/hook-out.txt") $L"
alive "$O3" && alive "$O5" && alive "$O4" && alive "$C" && ok "another task's file (same scratch directory), the same id in another scratch directory, an unrelated sleep and the claude are untouched" || bad "orphan survivors: O3=$(alive "$O3" && echo y) O5=$(alive "$O5" && echo y) O4=$(alive "$O4" && echo y) C=$(alive "$C" && echo y)"
hasline "$L" "stopped task tasksub7, pid $S \\(process group $S\\).*SIGTERM to process group $S, [0-9]+ descendant\\(s\\), 2 outside its tree: " && hasline "$L" "stopped task tasksub7, outside the shell's tree pid $O1, up [0-9]+ s, SIGTERM: sleep 301\$" && hasline "$L" "stopped task tasksub7, outside the shell's tree pid $O6, up [0-9]+ s, SIGTERM, SIGKILL after 0.3 s: " && [ "$(count_re "$L" "outside the shell's tree pid")" = 2 ] && ok "the log: the shell's line with both counts, one line per outside process (the SIGTERM-proof one marked SIGKILL), none for the others" || bad "orphan log: $L"
stop_claude "$C"; kill -KILL $O3 $O5 $O4 2>/dev/null

# the refusals: nothing stopped, exit 0, a line saying why
reset; transcript no tasksub1 "sleep 910; : subagent-job"
mkclaude "$GROUPED"; C=$FP; G=$(pidof_cmd "$C" subagent-job); printf '%s' "$(payload tasksub1)" > "$HOME/hook-in.json"; touch "$HOME/go"; waitfor '[ -s "$HOME/hook-out.txt" ]' 40
alive "$G" && [ "$(slurp "$HOME/hook-out.txt")" = "0|" ] && has "$(slurp "$SLOG")" "has not handed back, so it may be waiting for them: nothing stopped" && ok "a subagent that has not handed back (it may wait for its command): nothing stopped, the line says so" || bad "no handback: alive=$(alive "$G" && echo y) $(slurp "$SLOG")"
stop_claude "$C"
reset; transcript yes tasksub1 "sleep 999; : some other command"
mkclaude "$GROUPED"; C=$FP; G=$(pidof_cmd "$C" subagent-job); printf '%s' "$(payload tasksub1)" > "$HOME/hook-in.json"; touch "$HOME/go"; waitfor '[ -s "$HOME/hook-out.txt" ]' 40
alive "$G" && has "$(slurp "$SLOG")" "does not carry the subagent's command text: nothing stopped" && ok "the task id matches but the command text does not: nothing stopped" || bad "mismatch: alive=$(alive "$G" && echo y) $(slurp "$SLOG")"
stop_claude "$C"
reset; transcript yes tasksub1 "sleep 910; : subagent-job"
export SALA_SUBAGENT_CLEANUP=off; mkclaude "$GROUPED"; unset SALA_SUBAGENT_CLEANUP; C=$FP; G=$(pidof_cmd "$C" subagent-job); printf '%s' "$(payload tasksub1)" > "$HOME/hook-in.json"
touch "$HOME/go"; waitfor '[ -s "$HOME/hook-out.txt" ]' 40
alive "$G" && [ "$(slurp "$HOME/hook-out.txt")" = "0|" ] && [ ! -e "$SLOG" ] && ok "SALA_SUBAGENT_CLEANUP=off: nothing stopped, nothing logged" || bad "off: alive=$(alive "$G" && echo y) $(slurp "$SLOG")"
stop_claude "$C"
hook() { printf '%s' "$1" 2>/dev/null | "$SALA" hook subagent-stop; }
for x in '' 'not json' '{"background_tasks":[{"type":"shell","id":"a"}]}' "$(payload)" '{"agent_id":"../../x","agent_transcript_path":"/etc/passwd","background_tasks":[{"type":"shell","id":"a"}]}' \
          "{\"agent_id\":\"$AG\",\"agent_transcript_path\":\"$HOME/elsewhere.jsonl\",\"background_tasks\":[{\"type\":\"shell\",\"id\":\"a\"}]}"; do
    out=$(hook "$x" 2>&1); rc=$?; [ "$rc" = 0 ] && [ -z "$out" ] || bad "garbage input '${x:0:40}': rc=$rc out='$out'"
done; ok "empty, not JSON, no shell task, an agent id that is a path, a transcript that is not the subagent's: each exit 0 and silent"
reset; [ ! -e "$SLOG" ] && ok "none of them wrote a log line" || bad "log: $(slurp "$SLOG")"

echo "== a hook that runs under no registered claude stops nothing"
transcript yes tasksub1 "sleep 910; : subagent-job"
bash -c "setsid bash -c 'sleep 910; : subagent-job' > $HOME/tasks/tasksub1.output 2>&1 & echo \$! > $HOME/lone.pid; wait" & PIDS+=("$!"); waitfor '[ -s "$HOME/lone.pid" ]' 10
LONE=$(slurp "$HOME/lone.pid"); out=$(hook "$(payload tasksub1)"); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && alive "$LONE" && has "$(slurp "$SLOG")" "does not run under a registered claude" && ok "no registered claude above the hook: the shell is left alone, the line says so" || bad "no claude: rc=$rc alive=$(alive "$LONE" && echo y) $(slurp "$SLOG")"
kill "$LONE" 2>/dev/null

[ "$fail" = 0 ] && echo "ALL OK" || { echo "FAILED"; exit 1; }
