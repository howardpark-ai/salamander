#!/usr/bin/env bash
# verify.sh: drive the real `sala` and sala-web on a throwaway instance (the verify-sala skill, SKILL.md beside this file).
# Usage: verify.sh prove                    every journey in journeys/
#        verify.sh run <journey.sh>...      the named journeys: the skill's own, or a pull request's own file
# One call does it all: launch the instance, doctor, drive the journeys, keep the evidence, clean up. Nothing stays running.
# The instance runs in a bwrap sandbox (SKILL.md, Isolation): it has no way to the machine's processes, services, network or home.
# Exit 0: every check passed. 1: a check or a journey failed, or a process outlived the run. 2: no verdict, because the instance
# did not come up or the doctor failed (nothing was driven), or the call was wrong.
# Evidence: <checkout>/verify-evidence/<run>/, or under $VERIFY_SALA_EVIDENCE when that is set. It is kept after cleanup.
set -u
SELF=$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")
SKILL=$(dirname "$SELF")
ROOT=$(cd "$SKILL/../../.." && pwd -P)
SOCK=verify   # the tmux socket's name; its file lives in the scratch folder (TMUX_TMPDIR)
SYSPATH=/usr/local/bin:/usr/bin:/bin   # where the tools come from: the sandbox shows no other program folder
SYSDIRS="/usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin"
# commands that act past the instance (rights, power, services, schedules, other machines, containers, GitHub): recorded, not run
GUARDED="sudo sudo.ws sudoedit doas pkexec su runuser run0 shutdown reboot poweroff halt telinit kexec systemctl systemd-run
    loginctl busctl dbus-send machinectl crontab at ssh scp sftp rsync mosh tailscale docker podman gh"

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/, ""); print; next} {exit}' "$SELF"; }
no_verdict() { echo "verify-sala: $*" >&2; exit 2; }   # not `die`: lib/common.sh, sourced inside the instance, has its own

# ---------------------------------------------------------------- inside the instance: the helpers a journey calls
check() { local label="$1"; shift; if "$@"; then ok "$label"; else bad "$label"; fi; return 0; }   # <label> <command…>
not() { ! "$@"; }
under() { [[ $1 == "$HOME"/* ]]; }                                                          # <path> → inside the scratch folder
standins() {  # every guarded command is the stand-in, by name and at each system path; prints what is not
    local c d p miss=""
    for c in $GUARDED; do
        p=$(type -P "$c"); [ "$p" = "$HOME/stubs/$c" ] || miss+=" $c=${p:-none}"
        for d in $SYSDIRS; do [ ! -e "$d/$c" ] || grep -q '^# verify-sala stand-in' "$d/$c" 2>/dev/null || miss+=" $d/$c"; done
    done
    [ -z "$miss" ] || { echo "    not a stand-in:$miss"; return 1; }
}

sala() {  # <argv…> → runs the checkout's sala; OUT (stdout and stderr) and RC
    echo "\$ sala $*"
    OUT=$(bash "$ROOT/bin/salamander" "$@" 2>&1 </dev/null); RC=$?
    [ -z "$OUT" ] || sed 's/^/    /' <<< "$OUT"
    echo "    (exit $RC)"
}
start_session() {  # <tmux session> <conversation uuid> [VAR=value…]: a fake claude started by hand in a pane of its own
    local s="$1" u="$2" kv; shift 2; local e=(); for kv in "$@"; do e+=(-e "$kv"); done
    echo "\$ tmux new-session $s; claude   (conversation $u)"
    tmux new-session -d -s "$s" -x 120 -y 40 -c "$HOME/work" -e FAKE_SESSION_ID="$u" -e FAKE_NAME="$s" ${e[@]+"${e[@]}"}
    tmux send-keys -t "=$s:" claude Enter
    check "$s: a claude registered on its conversation" waitfor "reg_live '\"sessionId\":\"$u\"'" 40
}
next_spawn() { tmux set-environment -g FAKE_SESSION_ID "$1"; tmux set-environment -g FAKE_NAME "$2"; }   # <uuid> <name>: what the next claude that `sala spawn` starts registers as
claude_pid() { claude_pid_under "$(tmux display -p -t "=$1:" '#{pane_pid}')"; }            # <tmux session> → its claude's pid
screen() { tmux capture-pane -p -t "=$1:" | grep -v '^[[:space:]]*$'; }                     # <tmux session> → the pane's non-empty rows
map_row() { awk -F'\t' -v s="$1" '$1==s' "$SALA_SIDECAR" 2>/dev/null; }                     # <tmux session> → its pane-map row, empty when none
typed() { awk -v u="$1" '$1==u { sub(/^[^ ]+ /, ""); print }' "$FAKE_TYPED_LOG" 2>/dev/null; }   # <uuid> → the lines that reached its composer
new_cli_version() {  # <version>: the launcher now points at another binary, so every running claude is behind it (what a CLI update leaves)
    local v="$HOME/.local/share/claude/versions"
    [ -x "$v/$1" ] || cp "$v/9.9.9" "$v/$1"
    ln -sfn "$v/$1" "$HOME/.local/bin/claude"
    echo "\$ claude launcher → versions/$1"
}
web() {  # <METHOD> <path> [body [content type [Origin]]] → one request to the instance's sala-web; CODE and BODY
    [ -n "${WEBPID:-}" ] || { echo "this journey calls web: its file needs the line '# needs: web'"; exit 2; }
    local method="$1" path="$2" args=() n
    if [ $# -ge 3 ]; then args=(-H "Content-Type: ${4:-application/json}" --data-binary "$3"); fi
    [ -z "${5:-}" ] || args+=(-H "Origin: $5")
    n=$(( $(ls "$EVIDENCE/web" | wc -l) + 1 ))
    CODE=$(curl -sS -m 30 -X "$method" ${args[@]+"${args[@]}"} -o "$EVIDENCE/web/$n.body" -w '%{http_code}' --unix-socket "$HOME/web.sock" "http://localhost$path")
    BODY=$(cat "$EVIDENCE/web/$n.body" 2>/dev/null)
    echo "\$ web $method $path${3:+  $3}${5:+  (Origin: $5)}"
    echo "    HTTP $CODE  (body: web/$n.body)  $(head -c 300 <<< "$BODY" | tr '\n' ' ')"
}
json() { jq -e "$@" >/dev/null <<< "$BODY"; }                                               # [jq options…] <filter> → holds for BODY

# ---------------------------------------------------------------- the instance
doctor() {  # read only: is this the throwaway instance, is it empty, does it answer
    JOURNEY=doctor; echo "== doctor"
    local home; home=$(getent passwd "$EUID" | cut -d: -f6)
    check "HOME is the scratch folder, not the account's home" [ "$HOME" = "$VERIFY_SALA_INSTANCE" -a "$HOME" != "$home" ]
    check "sandbox: a process list of its own" [ "$(cat /proc/1/comm 2>/dev/null)" = bwrap ]
    check "sandbox: no network but its own loopback" [ "$(awk -F: 'NR>2 {gsub(/ /, "", $1); print $1}' /proc/net/dev)" = lo ]
    check "sandbox: no process can gain rights" grep -q $'^NoNewPrivs:\t1$' /proc/self/status
    check "sandbox: the machine's /run (service managers, message bus) is absent" [ ! -e /run ]
    local c   # named here as well as in GUARDED, so a name dropped from that list still fails
    for c in sudo systemctl shutdown reboot ssh; do check "$c resolves inside the instance" under "$(type -P "$c")"; done
    check "every guarded command is a stand-in, by name and by system path" standins
    check "sala's state folder is inside it" under "$SALA_STATE_DIR"
    check "sala's tmux socket is inside it" under "$(fleet_socket)"
    check "claude on PATH is inside it" under "$(command -v claude)"
    check "claude is the compiled fake" [ "$(claude --version)" = "9.9.9 (Claude Code)" ]
    check "tmux holds only the anchor session (and the web shell, which sala-web makes at start)" \
        [ "$(tmux list-sessions -F '#{session_name}' | grep -vx -e "$SALA_SHELL_SESSION")" = vs-anchor ]
    check "sala's registry folder is inside it" under "$SALA_REG_DIR"
    check "the registry holds no session" [ -d "$SALA_REG_DIR" -a -z "$(ls "$SALA_REG_DIR" 2>/dev/null)" ]
    sala spawn --list
    local other   # every row but the header and the anchor's own (a bare shell), whatever its version or name
    other=$(awk 'NR==1 && $1=="NAME" {next} $1=="vs-anchor" && $2=="(shell)" {next} {print}' <<< "$OUT")
    check "sala lists no session but the instance's anchor" [ "$RC" = 0 -a -z "$other" ]
    if [ -n "${WEBPID:-}" ]; then
        web GET /api/config
        check "sala-web answers on its socket" [ "$CODE" = 200 ]
        web GET /api/sessions
        check "sala-web lists no session" json '[.scopes[].groups[].sessions[]] | length == 0'
    fi
}

instance() {  # <checkout> <evidence folder> <0|1 web> <journey…>: runs inside the empty environment `outer` makes
    ROOT="$1"; EVIDENCE="$2"; local want_web="$3"; shift 3
    RESULTS="$EVIDENCE/results.txt"; JOURNEY=launch; WEBPID=""
    echo "== launch"
    # shellcheck source=/dev/null
    . "$ROOT/tests/lib.sh"   # the suites' own pieces: short timings, no outside calls, waitfor, reg_live, starts, uuid, has, as_op_unit
    # tests/lib.sh's ok and bad are a suite's; these take their place, so every result is also a line of results.txt
    ok() { echo "  ok   $*"; echo "ok    $JOURNEY: $*" >> "$RESULTS"; }
    bad() { echo "  FAIL $*"; echo "FAIL  $JOURNEY: $*" >> "$RESULTS"; }
    export SALA_CONFIG=/dev/null SALA_STACKSHOT_DIR="" SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" PYTHONDONTWRITEBYTECODE=1
    export SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off SALA_OP_STUCK=off SALA_OP_QUEUE=off SALA_MOD_WAIT=1 \
        SALA_RETRY_EVERY=2 SALA_RETRY_WINDOW=6
    export SALA_NOTIFY_CMD="cat >> $HOME/notify.txt" SALA_SNAPSHOT_CMD="touch $HOME/snapshot.done"
    export SALA_WEB_SALA_CMD="bash $ROOT/bin/salamander"
    mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect" \
        "$HOME/.local/share/claude/versions" "$HOME/work" "$TMPDIR" "$XDG_RUNTIME_DIR" "$EVIDENCE/web"
    chmod 700 "$XDG_RUNTIME_DIR"
    touch "$HOME/.claude/salamander-rc.stopped" "$HOME/.hushlogin"      # no Remote Control server here; no login banner in the panes
    cc -o "$HOME/.local/share/claude/versions/9.9.9" "$ROOT/tests/fake-claude.c" || no_verdict "the fake claude did not compile"
    ln -s "$HOME/.local/share/claude/versions/9.9.9" "$HOME/.local/bin/claude"
    as_op_unit   # the guarded verbs run here as the queue's runner would run them
    export SALA_TMUX_SOCKET="$TMUX_TMPDIR/tmux-$EUID/$SOCK"
    export FAKE_LOG="$HOME/fake.log" FAKE_TYPED_LOG="$HOME/typed.log"
    # the fake claude draws only its prompt row; sala and sala-web read an input box as a prompt row between two rules, as the CLI
    # draws it. The footer knob writes the lower rule under the prompt, then steps two rows up to write the upper one.
    local rule up down; printf -v rule '%*s' 60 ''; rule=${rule// /─}; up=$'\e[2A'; down=$'\e[2B'
    export FAKE_FOOTER="$rule$up"$'\r\e[K'"$rule$down"
    # shellcheck source=/dev/null
    . "$ROOT/lib/common.sh"
    eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux   # literal socket: sala's children run set -u
    tmux new-session -d -s vs-anchor -x 120 -y 40 -c "$HOME/work" || no_verdict "the private tmux server did not start"
    echo "  instance: HOME, tmux socket and web socket in one scratch folder; fake claude compiled from tests/fake-claude.c"
    if [ "$want_web" = 1 ]; then
        "$HOME/venv/bin/python" -m sala_web.app --socket "$HOME/web.sock" --tmux-socket "$SOCK" > "$EVIDENCE/web.log" 2>&1 &
        WEBPID=$!
        waitfor '[ "$(curl -s -m 5 -o /dev/null -w "%{http_code}" --unix-socket "$HOME/web.sock" http://localhost/api/config)" = 200 ]' 60 \
            || { tail -20 "$EVIDENCE/web.log"; no_verdict "sala-web did not answer (web.log)"; }
        echo "  sala-web: process $WEBPID on its own unix socket"
    fi

    doctor
    if grep -q '^FAIL  doctor: ' "$RESULTS"; then echo "verify-sala: the doctor failed, nothing was driven"; stop_instance; exit 2; fi

    local j n_ok n_bad failed=0
    for j in "$@"; do
        JOURNEY=$(basename "$j" .sh); echo "== journey $JOURNEY"
        # a subshell per journey: a journey that dies (an unset variable, an exit) fails itself and the next one still runs
        ( cd "$HOME/work" || exit 1; . "$j" ); rc=$?
        n_ok=$(grep -c "^ok    $JOURNEY: " "$RESULTS"); n_bad=$(grep -c "^FAIL  $JOURNEY: " "$RESULTS")
        [ "$rc" = 0 ] || bad "the journey file ended with status $rc"
        [ $(( n_ok + n_bad )) -gt 0 ] || bad "the journey made no check, so it proved nothing"
        if grep -q "^FAIL  $JOURNEY: " "$RESULTS"; then failed=1; echo "journey $JOURNEY: FAILED" | tee -a "$RESULTS"
        else echo "journey $JOURNEY: passed ($n_ok checks)" | tee -a "$RESULTS"; fi
    done
    stop_instance
    exit "$failed"
}

stop_instance() {  # keep the instance's own records as evidence, then stop what this shell started
    local f s
    for f in "$SALA_SIDECAR" "$FAKE_LOG" "$FAKE_TYPED_LOG" "$HOME/stubs.log" "$HOME/notify.txt" "$HOME/.claude/salamander-revive.log"; do
        [ ! -f "$f" ] || cp "$f" "$EVIDENCE/"
    done
    for s in $(tmux list-sessions -F '#{session_name}' 2>/dev/null); do
        echo "== $s"; tmux capture-pane -p -t "=$s:" 2>/dev/null | grep -v '^[[:space:]]*$'
    done > "$EVIDENCE/screens.txt"
    if [ -n "$WEBPID" ]; then kill "$WEBPID" 2>/dev/null; wait "$WEBPID" 2>/dev/null; fi
    return 0
}

# ---------------------------------------------------------------- outside the instance: make it, run it, remove it
SCRATCH=""; LEFT=0; CLEANED=""; SANDBOX=()
sandbox() {  # <scratch> <evidence folder> <journey…> → SANDBOX, the bwrap call the instance runs under
    local s="$1" ev="$2" c d t seen=" "; shift 2
    mkdir "$s/stubs" || return 1
    # one stand-in for every guarded command: it records the call and does nothing
    printf '%s\n' '#!/bin/sh' '# verify-sala stand-in: records the call, does nothing' "echo \"\${0##*/} \$*\" >> '$s/stubs.log'" \
        'case ${0##*/} in systemctl|systemd-run) exit 0 ;; *) exit 1 ;; esac' > "$s/stubs/stand-in" && chmod 755 "$s/stubs/stand-in" || return 1
    for c in $GUARDED; do ln -s stand-in "$s/stubs/$c" || return 1; done
    # new namespaces (no outside process, no network, no way to gain rights) and a file tree holding only what is named here
    SANDBOX=("$(command -v bwrap)" --unshare-user --unshare-ipc --unshare-pid --unshare-net --unshare-uts --unshare-cgroup-try
        --disable-userns --die-with-parent --new-session --ro-bind /usr /usr --ro-bind /etc /etc)
    for d in /bin /sbin /lib /lib32 /lib64; do
        if [ -L "$d" ]; then SANDBOX+=(--symlink "$(readlink "$d")" "$d"); elif [ -d "$d" ]; then SANDBOX+=(--ro-bind "$d" "$d"); fi
    done
    SANDBOX+=(--proc /proc --dev /dev --tmpfs /tmp --ro-bind "$ROOT" "$ROOT" --bind "$s" "$s" --ro-bind "$s/stubs" "$s/stubs" --bind "$ev" "$ev")
    for t in "$@"; do [[ $t == "$ROOT"/* ]] || SANDBOX+=(--ro-bind "$t" "$t"); done
    for c in $GUARDED; do   # over the system's own copy too, so a call by full path is recorded like one by name
        for d in $SYSDIRS; do
            [ -e "$d/$c" ] || continue
            t=$(readlink -f "$d/$c"); [[ $seen != *" $t "* ]] || continue; seen+="$t "
            SANDBOX+=(--ro-bind "$s/stubs/stand-in" "$t")
        done
    done
    SANDBOX+=(--chdir "$s")
}
marked() {  # <scratch> → the processes this run started: the ones whose starting environment names this run's scratch folder
    local e p
    for e in /proc/[0-9]*/environ; do
        grep -qzxF "VERIFY_SALA_INSTANCE=$1" "$e" 2>/dev/null || continue
        p=${e#/proc/}; echo "${p%/environ}"
    done
}
cleanup() {
    [ -n "$SCRATCH" ] && [ -z "$CLEANED" ] || return 0
    CLEANED=1
    local s="$SCRATCH" sig p i
    # nothing here connects to a path in the scratch folder: a journey can leave a link there that leads to a server outside
    for sig in TERM KILL; do
        for p in $(marked "$s"); do kill -"$sig" "$p" 2>/dev/null; done
        for i in 1 2 3 4 5 6 7 8 9 10; do [ -n "$(marked "$s")" ] || break; sleep 0.2; done
    done
    LEFT=$(marked "$s" | grep -c .)
    exec 8<&-
    rm -rf "$s"
}

outer() {
    local mode="$1"; shift
    local journeys=() j t
    case $mode in
        prove) [ $# -eq 0 ] || no_verdict "prove takes no argument"; journeys=("$SKILL"/journeys/*.sh) ;;
        run) [ $# -gt 0 ] || no_verdict "run needs a journey file"; journeys=("$@") ;;
    esac
    for j in "${!journeys[@]}"; do
        t=${journeys[$j]}; [ -f "$t" ] || no_verdict "no journey file $t"
        journeys[$j]=$(cd "$(dirname "$t")" && pwd -P)/$(basename "$t")
    done
    [ "$(uname -s)" = Linux ] || no_verdict "the instance needs Linux (/proc)"
    for t in bwrap flock tee; do command -v "$t" >/dev/null || no_verdict "missing tool: $t"; done
    for t in bash tmux python3 cc jq curl git; do PATH=$SYSPATH command -v "$t" >/dev/null || no_verdict "missing system tool: $t (in $SYSPATH)"; done
    local want_web=0; ! grep -q '^# needs: web' "${journeys[@]}" || want_web=1

    local base="${VERIFY_SALA_EVIDENCE:-$ROOT/verify-evidence}" evidence
    mkdir -p "$base" && evidence=$(mktemp -d "$base/$(date +%Y%m%d-%H%M%S)-XXXX") && evidence=$(cd "$evidence" && pwd -P) \
        || no_verdict "cannot make the evidence folder under $base"
    : > "$evidence/results.txt"

    trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM HUP
    SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/vs.XXXXXX") || no_verdict "no scratch folder"
    SCRATCH=$(cd "$SCRATCH" && pwd -P)
    exec 8< "$SCRATCH"; flock -n 8 || no_verdict "cannot lock the scratch folder"   # an age-based sweep of the temp folder skips it
    [ "${#SCRATCH}" -le 75 ] || no_verdict "the scratch path is too long for a unix socket (${#SCRATCH} characters): set TMPDIR to a shorter folder"

    if [ "$want_web" = 1 ]; then   # built before the environment is emptied, so uv keeps its own download cache
        command -v uv >/dev/null || no_verdict "missing tool: uv (a journey needs the web app)"
        # the locked dependencies only, as wheels: nothing of the checkout is built or run out here, outside the sandbox
        UV_PROJECT_ENVIRONMENT="$SCRATCH/venv" UV_LINK_MODE=copy UV_PYTHON_DOWNLOADS=never UV_COMPILE_BYTECODE=0 uv sync --frozen --no-dev --no-install-project \
            --no-build --python "$(PATH=$SYSPATH command -v python3)" --project "$ROOT/web" > "$evidence/uv-sync.log" 2>&1 \
            || { tail -20 "$evidence/uv-sync.log" >&2; no_verdict "uv sync of web/ failed (uv-sync.log)"; }
        local site; for site in "$SCRATCH"/venv/lib/python*/site-packages; do echo "$ROOT/web/src" > "$site/sala_web_src.pth"; done
    fi

    sandbox "$SCRATCH" "$evidence" "${journeys[@]}" || no_verdict "cannot prepare the sandbox"
    # an empty environment: no setting, token or tmux server of the machine reaches the instance
    env -i HOME="$SCRATCH" PATH="$SCRATCH/.local/bin:$SCRATCH/stubs:$SYSPATH" TMPDIR="$SCRATCH/tmp" TMUX_TMPDIR="$SCRATCH" \
        XDG_RUNTIME_DIR="$SCRATCH/run" LANG=C.UTF-8 LC_ALL=C.UTF-8 TERM=xterm-256color SHELL=/bin/bash \
        VERIFY_SALA_INSTANCE="$SCRATCH" "${SANDBOX[@]}" -- "$(PATH=$SYSPATH command -v bash)" "$SELF" __instance "$ROOT" "$evidence" "$want_web" "${journeys[@]}" </dev/null 2>&1 \
        | tee "$evidence/transcript.txt"
    local rc=${PIPESTATUS[0]} gone="not removed" n_ok n_bad verdict
    local s="$SCRATCH"; cleanup
    find "$evidence" ! -type f ! -type d -delete 2>/dev/null   # a journey writes there: never append through a link it left
    [ -e "$s" ] || gone=removed
    if [ "$LEFT" != 0 ] || [ "$gone" != removed ]; then [ "$rc" != 0 ] || rc=1; fi
    n_ok=$(grep -c '^ok    ' "$evidence/results.txt"); n_bad=$(grep -c '^FAIL  ' "$evidence/results.txt")
    case $rc in 0) verdict=PASS ;; 1) verdict=FAIL ;; *) verdict="NO VERDICT (exit $rc)" ;; esac
    {
        echo "cleanup: $LEFT processes left, scratch folder $gone"
        echo "verify-sala: $verdict ($n_ok checks passed, $n_bad failed, ${#journeys[@]} journeys named)"
    } | tee -a "$evidence/results.txt" "$evidence/transcript.txt"
    echo "evidence: $evidence"
    exit "$rc"
}

case ${1:-} in
    prove|run) outer "$@" ;;
    __instance) shift; instance "$@" ;;
    -h|--help) usage ;;
    *) usage >&2; exit 2 ;;
esac
