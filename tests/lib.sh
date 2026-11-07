# tests/lib.sh — the prelude every suite sources right after it sets ROOT:  . "$ROOT/tests/lib.sh"
# Not a suite (tests/run.sh skips it). It holds three things, and a new suite (tests/<name>.sh) sources it the same way:
#
# 1. SHORT TIMINGS. sala's waits run at production length unless a suite shortens them; every one a suite waits through is
#    an env var with its production default in lib/ (`: "${SALA_X:=default}"`), set short here. A suite may still set its
#    own value for one step (sets.sh sets SALA_RETRY_EVERY per case). Production defaults are unchanged.
#      SALA_EXIT_WAIT    30 → 5   a typed /exit landing (phases: the pane that ignores /exit runs into it)
#      SALA_RESUME_WAIT  30 → 5   the resumed claude live in its pane (phases and sets-master: the resume that comes up and
#                                 dies 10 s in is caught inside it, on the one command each that sets 20; sets-master's master
#                                 registering 6 s in runs past it)
#      SALA_SELF_WAIT   900 → 20  the self-worker waiting for the invoking pane to go idle (sets sets 3 where it must expire)
#      SALA_READY_WAIT   90 → 20  a retry worker waiting for a `ready` pane's turn to end
#      SALA_RC_SERVED_WAIT 120 → 10  served sessions back after a Remote Control server restart (no server in the suites)
#      SALA_SNAPSHOT_DELAY  4 → 1   a snapshot coalescing a burst of tmux events
#      SALA_RESUME_GAP      1 → 0   the gap between two resumes of a sweep (phases sets its own 2 where it checks the gap)
#      SALA_HOLD_SETTLE     3 → 0.2 revive: the pause between holding every pane's inbox and the first /exit (phases runs the default 3 where it
#                                 sends a late message to a held pane inside it and measures the settle)
#      SALA_SPAWN_SETTLE    3 → 0.2 spawn: the pause before it types /rename (the fake claude reads at once)
#      SALA_SHELL_SETTLE    1 → 0.2 spawn: the pause after the launch line's Enter before it looks for ble.sh's multiline banner
#      SALA_RENAME_SETTLE   5 → 0.2 spawn: the pause after /rename before it reads the registry (it retries every 2 s anyway)
#      SALA_BRIDGE_SETTLE  20 → 0.5 watch: the pause after it types /remote-control before it reads the bridge id back (the
#                                 fake claude's registry row carries one from the start; lanes checks that the line was typed)
#      SALA_RECYCLE_GATHER, SALA_RECYCLE_GATHER_MAX, SALA_RECYCLE_REST  600/1800/1800 → 0   the job's gathering of flags and a pane's rest after
#                                 a relaunch: the fake claudes start seconds before a recycle and every suite relaunches
#                                 them at once, so the three waits are off here; tests/flags.sh turns them back on
#    SALA_IDLE_SETTLE (is_idle's 10 s settle) stays at its default: no suite waits through it (the fake claude stamps its
#    registry row 60 s old), and busyhooks checks the settle with a row 3 s old.
#    SALA_SIGNIN_ALERT is OFF here: watch's sign-in step runs `timeout 30 claude auth status --json` per
#    login lane, and the compiled fake claude does not answer it, so every suite's first `watch` tick sat 30 s per lane (60 s
#    with a team directory) for a verdict nothing checked, and its api probe went to the real API with the suite's dummy key.
#    tests/signin.sh, the step's own suite with a fake that answers, turns it back on after sourcing this file.
#
# 2. HELPERS: ok / bad (a check's line; bad sets fail=1), waitfor '<condition>' [half-seconds] (default 30 s; the condition's
#    own status at the end). Wait for a condition, never a fixed sleep, wherever one exists.
#
#    deny_load / deny_have / deny_count / deny_at / deny_files: the checks that no owner's private value is in a file or an output
#    read the deny source at run time (tests/deny_source.py), never a literal here; none on the machine = those checks skip, with a notice.
#
#    reg_live / fake_up: wait for the fake claude by its registry row instead of a fixed sleep after starting it.
#
#    FEWER PROCESSES, LOAD-PROOF WAITS (Mon Oct 26th 2026): the suites started thousands of short processes and were
#    most of the coordinator's CPU load, which in turn failed the timing-sensitive suites in CI.
#      nap <secs>          a sleep that starts no process: `read -t` on a pipe nothing writes to (bash 4.2+; falls back to sleep)
#      load_factor         sets LOAD_FACTOR, 1 on a quiet box up to 6 when the 1-minute load is many times the cores
#      waitfor             polls at 0.1 s, then 0.2, 0.4, 0.8, 1 s (a wait that holds at once or soon costs one or two evaluations,
#                          a long one about 35 instead of 60), and its deadline is the stated one times LOAD_FACTOR
#      lock_wait <file> <secs>  one blocking `flock -w` (the secs times LOAD_FACTOR) instead of a poll of `flock -n` and sleeps;
#                          the suites' wait_lock lines call it
#      scale <secs>        <secs> times LOAD_FACTOR, for a suite's own bounded wait (`timeout "$(scale 20)" …` as `$(scale 20)`)
#    A suite that must see something NOT happen still waits a fixed time: only a wait for a thing to happen is scaled.
#    tests/count-procs.sh counts the processes a suite starts (the before/after of this).
#
# 3. CLEANUP: tmux_socket_rm removes this suite's socket file after its server is killed (SALA_TMUX_SOCKET; given names,
#    only those: a second server's socket mid-suite), so /tmp/tmux-<uid> does not collect a stale sala-* socket per run.
#
# 4. THE LANE VARIABLES a suite inherits are unset here: CLAUDE_CODE_ENTRYPOINT, ANTHROPIC_API_KEY, ANTHROPIC_CUSTOM_HEADERS,
#    CLAUDE_CONFIG_DIR, and the bedrock and aws-platform lanes' own (CLAUDE_CODE_USE_BEDROCK, CLAUDE_CODE_USE_ANTHROPIC_AWS,
#    AWS_PROFILE, AWS_REGION, ANTHROPIC_BEDROCK_REGION_PREFIX: _proc_lane_r reads the two flags, so a run from a Bedrock-lane
#    pane made every fake read as bedrock). A suite run from a pane on the sdk or api lane inherits its CLI's environment (sdk-py, the key), the
#    tmux server it starts hands it to every pane, and every fake claude then reads as sdk or api to proc_lane: the sweeps
#    refuse each pane for a lane mismatch ("runs on the sdk lane but has no lane row") and several suites fail at once. CI's runner carries none of them; this keeps a run from any pane
#    equal to CI's. A suite that wants one sets it itself, after sourcing this file.
#
# 5. THE QUEUE'S CGROUP ("No master session", Thu Oct 15th 2026): with no master configured the guards refuse a
#    fleet verb called by a Claude session (claude_caller in lib/common.sh) and point it to `sala op`, and a suite run from a
#    Claude session's pane is such a caller. A suite that runs a guarded verb itself on a target that is not sala-test-*
#    (recycle, revive --force, restore --missing, lane default, provision, adopt, a retire by conversation id) calls
#    `as_op_unit` right after it sets its HOME:
#    SALA_CGROUP_FILE then names a sala-op-<id> unit, and the suite's own calls stand for the queue's runner (op_unit_caller
#    admits them), from a Claude session's pane and from CI alike. The guards themselves are checked in op.sh and nomaster.sh.
#
# Each suite keeps its own temporary HOME and private tmux socket (sala-<suite>-$$), so tests/run.sh runs them side by side.

unset CLAUDE_CODE_ENTRYPOINT ANTHROPIC_API_KEY ANTHROPIC_CUSTOM_HEADERS CLAUDE_CONFIG_DIR
unset CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_ANTHROPIC_AWS AWS_PROFILE AWS_REGION ANTHROPIC_BEDROCK_REGION_PREFIX
unset ENABLE_PROMPT_CACHING_1H ENABLE_PROMPT_CACHING_1H_BEDROCK   # a runner that sets them (this box does) would read as the lane's cache switch in the checks that watch it
export SALA_EXIT_WAIT=5 SALA_RESUME_WAIT=5 SALA_SELF_WAIT=20 SALA_READY_WAIT=20 SALA_RC_SERVED_WAIT=10 SALA_SNAPSHOT_DELAY=1 \
    SALA_RESUME_GAP=0 SALA_HOLD_SETTLE=0.2 SALA_SPAWN_SETTLE=0.2 SALA_SHELL_SETTLE=0.2 SALA_RENAME_SETTLE=0.2 SALA_BRIDGE_SETTLE=0.5
export SALA_RECYCLE_GATHER=0 SALA_RECYCLE_GATHER_MAX=0 SALA_RECYCLE_REST=0   # the waits are flags.sh's (the header)
export SALA_UNIT_GAPS=off      # watch's unit-gap pass reads the real /etc/systemd/system and may message the board; tests/jobs.sh turns it on with temporary folders
export SALA_JOB_LANE=max       # sala's own scheduled model calls (the stuck-operation helper, the parked-question sweep) run on bedrock in production;
                               # the suites stub the command, and CI's runner has no bedrock profile. tests/bedrocklane.sh checks the lane
export SALA_LANE_BEDROCK_PROFILE=example-bedrock SALA_LANE_AWSPLATFORM_PROFILE=example-bedrock   # the AWS profiles have no default (empty = unset); the lane suites use the fixture profile name
                               # they always have, as a config line would set it. tests/neutral-defaults.sh checks the empty default with these unset
export SALA_LANE_BEDROCK_REGION=us-east-1 SALA_LANE_AWSPLATFORM_REGION=us-east-1   # the regions have no default either (empty = the lane is not set up); the lane suites use a fixture region
export SALA_TZ=Etc/UTC     # with no zone set every time sala shows is the machine's local time (CI's runner is UTC); the suites' expected times and labels
                               # are a fixed zone, as a config line would set it. tests/neutral-defaults.sh checks the unset default with this unset
export SALA_OWNER_NAME=Rowan     # the name runtime text and the `[for <name>]` marker carry; the suites' expected text says Rowan. tests/neutral-defaults.sh checks the unset default ("the owner")
export SALA_SIGNIN_ALERT=off  # the sign-in step is signin.sh's (the header): a 30 s hang per login lane for the other suites
export SALA_LANE_FALLBACK_AUTO=off   # a lane that turns dormant (watch, `lane dormant`) would queue a move through `sala op` and kick the real systemd-run;
                               # the other suites keep the older "stays where it is" behaviour. tests/lanefallback.sh turns the switch on, with its own stubs
export SALA_MODEL_INPLACE=off  # `sala model` on an idle pane would type /model into the fake claude, which answers nothing; the suites that
                               # check the relaunch (models.sh, op.sh) keep checking it. tests/modelinplace.sh turns the switch back on
export SALA_MODEL_INPLACE_SETTLE=0.3 SALA_MODEL_INPLACE_WAIT=8   # and shortens its two waits (production: 1 s, 20 s)
export SALA_RETIRE_ITEMS_CMD='echo {\"items\":[]} #'   # retire asks stackshot what the session moves before it acts (common.sh, RETIRE ASKS FOR OPEN ITEMS FIRST); the suites answer "nothing"
                               # (the trailing # drops the key the command is handed), and no suite reaches a real stackshot. tests/retire-verbs.sh stubs a client with items, none and unreachable

fail=0
ok() { echo "  ok   $*"; }
bad() { echo "  FAIL $*"; fail=1; }
# The deny source (see tests/deny_source.py): a suite that guards against an owner's private values never names one; it asks the
# deny source clean_text.py reads, and skips those checks, with one notice, where there is none (a public runner). Nothing prints a pattern.
#   deny_load <file>   copy the deny source into <file> (mode 600; the suite's own temp folder) and set DENY_FILE; call it before the
#                      suite changes HOME. No source: DENY_FILE is empty and one notice line says the checks are skipped. A line that
#                      is not a valid regex is a failed check.
#   deny_have          status 0 when a deny source is loaded
#   deny_count [file]  how many lines of the file (default: stdin) match a rule;  deny_at [file]  their line numbers, comma separated
#   deny_files         names (stdin, one per line) of the files that hold a match
DENY_FILE=""
deny_load() {
    local rc
    DENY_FILE=""
    python3 -I "$ROOT/tests/deny_source.py" dump "$1"; rc=$?
    case $rc in
        0) DENY_FILE=$1 ;;
        1) echo "  skip the deny-source checks: no deny source (CLEAN_TEXT_DENY, or the file ~/.config/salamander/clean-text-deny) on this machine" ;;
        *) bad "the deny source could not be read (rc=$rc)" ;;
    esac
}
deny_have() { [ -n "$DENY_FILE" ]; }
deny_count() { python3 -I "$ROOT/tests/deny_source.py" hits "$DENY_FILE" "${1:--}" | cut -d' ' -f1; }
deny_at() { python3 -I "$ROOT/tests/deny_source.py" hits "$DENY_FILE" "${1:--}" | cut -d' ' -f2; }
deny_files() { python3 -I "$ROOT/tests/deny_source.py" files "$DENY_FILE"; }
{ exec {NAP_FD}<> <(:); } 2>/dev/null || NAP_FD=""   # a pipe nothing writes to: reading it with a timeout is a sleep with no process (the fd is >= 10)
nap() { local _t="${1:-0.5}"; if [ -n "${NAP_FD:-}" ]; then { read -r -t "$_t" -u "$NAP_FD" _; } 2>/dev/null; [ $? -gt 128 ] && return 0; fi; sleep "$_t"; }   # <secs>: a timeout is the sleep; any other status (no pipe) falls back to sleep
NCPU=0; while read -r _k _; do [ "$_k" = processor ] && NCPU=$((NCPU+1)); done < /proc/cpuinfo 2>/dev/null; [ "$NCPU" -ge 1 ] || NCPU=1
load_factor() {  # → LOAD_FACTOR: 1 while the 1-minute load is under the core count, +1 per whole multiple of it, at most 6
    local l _; LOAD_FACTOR=1; read -r l _ < /proc/loadavg 2>/dev/null || return 0
    LOAD_FACTOR=$(( ${l%%.*} / NCPU + 1 )); [ "$LOAD_FACTOR" -le 6 ] || LOAD_FACTOR=6; return 0
}
scale() { load_factor; echo $(( $1 * LOAD_FACTOR )); }   # <secs> → the deadline for a wait on a thing that must happen, longer when the box is loaded
waitfor() {  # <condition> [half-seconds] → the condition's status once it holds, or its last status at the deadline (the half-seconds, times the load factor)
    local rc d=0.1 t0=$SECONDS limit
    load_factor; limit=$(( (${2:-60} * LOAD_FACTOR + 1) / 2 ))
    while :; do
        eval "$1"; rc=$?; [ "$rc" = 0 ] && return 0
        [ $(( SECONDS - t0 )) -gt "$limit" ] && return "$rc"
        nap "$d"; case $d in 0.1) d=0.2;; 0.2) d=0.4;; 0.4) d=0.8;; *) d=1;; esac
    done
}
lock_wait() {  # <lock file> <secs> — returns once nobody holds the flock, or after <secs> (times the load factor): one blocking flock, no poll
    command -v flock >/dev/null 2>&1 || { sleep 3; return 0; }
    load_factor; flock -w $(( ${2:-80} * LOAD_FACTOR )) "$1" true 2>/dev/null; return 0
}

# typed_ctx <typed.log> [<fake uuid>] → what a failed check on FAKE_TYPED_LOG needs in its log line: that the file does not exist (with the
# registry rows of the fakes that came up), or its line count and the last five lines (the fake's own when a uuid is given). A `grep` on a
# missing file printed nothing, and a "typed: " message with an empty tail told the runner's log nothing (the CI box, Oct 27th).
typed_ctx() {
    local f=$1 u=${2:-} n=0 l k t="" rows=""
    if [ ! -e "$f" ]; then
        for k in "$HOME"/.claude/sessions/*.json; do [ -e "$k" ] && rows+="${k##*/} "; done
        printf '[%s does not exist; fakes with a registry row: %s]%s' "$f" "${rows:-none}" "$(typed_diag "$f")"; return 0
    fi
    { while IFS= read -r l || [ -n "$l" ]; do n=$((n + 1)); if [ -z "$u" ] || [[ $l == "$u "* ]]; then t+="$l"$'\n'; fi; done < "$f"; } 2>/dev/null
    printf '[%s: %s line(s)%s]%s' "$f" "$n" "$([ -n "$t" ] && printf ', last of them:\n%s' "$(printf '%s' "$t" | tail -n 5)" || echo ', none of them the fakes own')" "$(typed_diag "$f")"
}
# typed_diag <typed.log> → the state a fake that never read its line was in, for the failure line (on a CI runner,
# mod.sh's brief line and spawn.sh's orientation lines never reached the fake's composer, repeatably on an idle box, and the log said
# only that the file was missing). Who runs the suite and where its files live; the typed.log directory; for every fake with a registry
# row its liveness, state (ps: STAT, process group against the terminal's foreground group TPGID — a stopped "T" or pgid != tpgid is a
# read refused to a background group — and WCHAN, where it sleeps), what its stdin is (/proc/<pid>/fd/0) and that descriptor's flags
# (octal; 04000 is O_NONBLOCK, which would make fgets fail at once with EAGAIN); and each tmux pane's last screen lines (a launch error,
# the fake's own "stdin ended" line from fake-claude.c). Runs only on a failed check, so it may start as many processes as it likes.
typed_diag() {
    local f=$1 k p out="" d fl scr id
    d=$(dirname "$f")
    out+=$'\n'"  diag: user=$(id -un 2>&1) uid=$EUID HOME=$HOME TMPDIR=${TMPDIR:-<unset>} TERM=${TERM:-<unset>} LANG=${LANG:-<unset>} LC_ALL=${LC_ALL:-<unset>} shell=${SHELL:-<unset>}"
    out+=$'\n'"  diag: dir $(ls -ld "$d" 2>&1 | head -1); $(ls -la "$d" 2>&1 | sed -n '2,30p' | awk '{print $1, $3, $5, $NF}' | paste -sd'|')"
    out+=$'\n'"  diag: $(df -P "$d" 2>/dev/null | awk 'NR==2 {print $1, $4 " KB free,", $5 " used, on " $6}'); $(findmnt -no FSTYPE,OPTIONS -T "$d" 2>/dev/null | head -1)"
    for k in "$HOME"/.claude/sessions/*.json; do
        [ -e "$k" ] || continue; p=${k##*/}; p=${p%.json}
        if kill -0 "$p" 2>/dev/null; then
            fl=$(awk '/^flags:/ {print $2}' "/proc/$p/fdinfo/0" 2>/dev/null)
            out+=$'\n'"  diag: fake pid $p alive: $(ps -o pid=,stat=,pgid=,tpgid=,tty=,wchan:20=,comm= -p "$p" 2>&1 | head -1 | tr -s ' ')"
            out+=$'\n'"  diag:   stdin $(ls -l "/proc/$p/fd/0" 2>&1 | awk '{print $(NF-2), $(NF-1), $NF}') flags=${fl:-?} (octal; 04000 = O_NONBLOCK)$([ -n "$fl" ] && [ $(( 8#$fl & 8#4000 )) -ne 0 ] && echo ' NONBLOCK')"
        else out+=$'\n'"  diag: fake pid $p: dead (a stale registry row)"; fi
    done
    for id in $(tmux list-panes -a -F '#{pane_id}' 2>/dev/null | head -8); do
        scr=$(tmux capture-pane -p -t "$id" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -6 | cut -c1-160 | paste -sd'|')
        out+=$'\n'"  diag: pane $id $(tmux display -p -t "$id" '#{session_name} cmd=#{pane_current_command} mode=#{pane_in_mode} #{pane_width}x#{pane_height}' 2>/dev/null): ${scr:-<empty>}"
    done
    printf '%s' "$out"
}

# reg_live <text> → 0 when a live process has a registry row (~/.claude/sessions/<pid>.json) containing <text>, e.g.
# '"name":"sala-test-a"' or '"sessionId":"<uuid>"'. The fake claude writes its row, then shows its ❯ prompt.
reg_live() { local f p c; for f in "$HOME"/.claude/sessions/*.json; do [ -e "$f" ] || continue; c=""; { IFS= read -r -d '' c < "$f"; } 2>/dev/null; [[ $c == *"$1"* ]] || continue; p=${f##*/}; p=${p%.json}; kill -0 "$p" 2>/dev/null && return 0; done; return 1; }   # (the file read by the shell, not grep -F)
fake_up() {  # <FAKE_NAME>… — wait (up to 20 s each) until a fake claude runs under each name; instead of a fixed sleep after starting one
    local n; for n in "$@"; do waitfor "reg_live '\"name\":\"$n\"'" 40 || { echo "  (fake claude '$n' did not come up)"; return 1; }; done; }

# ── helpers the suites shared as copies (a copy per suite, each starting a process or three per call) ──────────────────
# Their bodies are the shell's own; a suite that needs a different shape defines its own after sourcing this file.
# kill_fake_claude <fake-binary-path> - kill the test's own fake claude processes and nothing else (an unguarded
# `for p in $(pgrep -x claude); do kill -9 $p` took down every real pane on the box). A process dies only when its /proc/<pid>/exe IS
# that exact binary AND its environment holds HOME=$HOME of this test; it refuses (kills nothing, status 1) when the path is not an
# executable under $HOME, or when $HOME is the user's real home. Never `pgrep -x claude` + kill in a test: tests/syntax.sh fails on it.
kill_fake_claude() {
    local bin="${1:-}" p real
    [ -n "$bin" ] && [ -x "$bin" ] && [ -n "${HOME:-}" ] && [[ $bin == "$HOME"/* ]] || { echo "kill_fake_claude: '$bin' is not a fake under \$HOME ($HOME)" >&2; return 1; }
    real=$(getent passwd "$EUID" | cut -d: -f6); { [ "$HOME" != "$real" ] && [ "$HOME" != / ]; } || { echo "kill_fake_claude: refused, \$HOME is the real home" >&2; return 1; }
    for p in /proc/[0-9]*; do
        p=${p#/proc/}
        [ "$bin" -ef "/proc/$p/exe" ] 2>/dev/null || continue
        grep -qz "^HOME=$HOME\$" "/proc/$p/environ" 2>/dev/null || continue
        kill -9 "$p" 2>/dev/null
    done
    return 0
}
uuid() { printf '%08x-0000-4000-8000-%012x' "$1" "$1"; }   # <n> → a fixed-shape uuid for fake session n
has() { [[ $1 == *"$2"* ]]; }                               # <text> <needle> → 0 when the text holds the needle (grep -qF)
cpid() { claude_pid_under "$(tmux display -p -t "=sala-test-$1:" '#{pane_pid}')"; }   # <suffix> → the pid of the claude in tmux session sala-test-<suffix>
starts() { local n=0 l; [ -r "$FAKE_LOG" ] || return 0; { while IFS= read -r l || [ -n "$l" ]; do [[ $l == "start $1 "* ]] && n=$((n + 1)); done < "$FAKE_LOG"; } 2>/dev/null; echo "$n"; }   # <uuid> → how many times a fake started on it
# the Slack posts a suite's fake poster appends to $POSTS: each post is its lines, a headline unindented, the rest indented, then a "%%" line
posts() { local n=0 l; { while IFS= read -r l || [ -n "$l" ]; do [[ $l == [!\ ]* ]] && n=$((n + 1)); done < "$POSTS"; } 2>/dev/null; echo "$n"; }   # how many posts
_posts_read() { POSTS_ALL=""; { IFS= read -r -d '' POSTS_ALL < "$POSTS"; } 2>/dev/null || :; }
post() { local rest sep=$'%%\n' rec; _posts_read; rest=$POSTS_ALL; while [ -n "$rest" ]; do if [[ $rest == *"$sep"* ]]; then rec=${rest%%"$sep"*}; rest=${rest#*"$sep"}; else rec=$rest; rest=""; fi; [[ $rec == *"$1"* ]] && { printf '%s' "$rec"; return 0; }; done; return 0; }   # <text> → the first post holding it
nposts() { local rest sep=$'%%\n' rec n=0; [ -r "$POSTS" ] || return 0; _posts_read; rest=$POSTS_ALL; while [ -n "$rest" ]; do if [[ $rest == *"$sep"* ]]; then rec=${rest%%"$sep"*}; rest=${rest#*"$sep"}; else rec=$rest; rest=""; fi; [[ $rec == *"$1"* ]] && n=$((n + 1)); done; echo "$n"; }   # <text> → how many posts hold it
lastpost() { local l p=""; { while IFS= read -r l || [ -n "$l" ]; do [[ $l == [!\ ]* ]] && p=""; p+="$l"$'\n'; done < "$POSTS"; } 2>/dev/null; printf '%s' "$p"; }   # the newest post, whole
iso() { TZ=UTC printf '%(%Y-%m-%dT%H:%M:%S.000Z)T\n' "$1"; }   # <epoch> → the CLI's timestamp form
rid() { printf 'eeeeeeee-0000-4000-8000-%04x%04x%04x' $((RANDOM % 65536)) $((RANDOM % 65536)) $((RANDOM % 65536)); }   # a fresh record uuid
slurp() { local _t=""; { IFS= read -r -d '' _t < "$1"; } 2>/dev/null; printf '%s' "$_t"; }   # <file> → its text; for `$(slurp f)` where $(cat f 2>/dev/null) stood (no process; a missing file reads as empty)
same_file() {  # <a> <b> → 0 when the two files hold the same bytes (cmp -s; "-" is stdin; the shell's reads: a NUL byte is not told apart, these are text)
    local _a _b; [ "$1" = - ] || [ -r "$1" ] || return 1; [ "$2" = - ] || [ -r "$2" ] || return 1
    if [ "$1" = - ]; then { IFS= read -r -d '' _a; } 2>/dev/null || :; else { IFS= read -r -d '' _a < "$1"; } 2>/dev/null || :; fi
    if [ "$2" = - ]; then { IFS= read -r -d '' _b; } 2>/dev/null || :; else { IFS= read -r -d '' _b < "$2"; } 2>/dev/null || :; fi
    [ "$_a" = "$_b" ]
}
set_reg_status() {  # <pid> <status> → that claude's registry row says <status> now (the first "status":"…" in it)
    local f="$HOME/.claude/sessions/$1.json" t; { IFS= read -r -d '' t < "$f"; } 2>/dev/null || :
    [[ $t =~ \"status\":\"[a-z]*\" ]] && t=${t/"${BASH_REMATCH[0]}"/\"status\":\"$2\"}
    printf '%s' "$t" > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"   # a temp file in the same directory and a rename: a reader never sees the row half written or empty
}
enq() { OUT=$("$SALA" op "$@" 2>&1); RC=$?; ID=""; local l; while IFS= read -r l; do if [[ $l =~ ^queued\ op\ ([0-9-]*): ]]; then ID=${BASH_REMATCH[1]}; break; fi; done <<< "$OUT"; }   # → OUT, RC and the queued op's ID

as_op_unit() {  # this suite's own fleet verbs run as the queue's runner would (the header, 5): a cgroup file naming a sala-op-<id> unit
    echo "0::/user.slice/user-$EUID.slice/user@$EUID.service/app.slice/sala-op-1760000000-1.service" > "$HOME/op-unit.cgroup"
    export SALA_CGROUP_FILE="$HOME/op-unit.cgroup"
}

tmux_socket_rm() {  # [socket name…] — after kill-server: this suite's socket file (SALA_TMUX_SOCKET), or only the named ones
    local d="${TMUX_TMPDIR:-/tmp}/tmux-$EUID" s
    if [ $# -eq 0 ]; then [ -n "${SALA_TMUX_SOCKET:-}" ] && rm -f "$SALA_TMUX_SOCKET" 2>/dev/null
    else for s in "$@"; do rm -f "$d/$s" 2>/dev/null; done; fi
    return 0
}
