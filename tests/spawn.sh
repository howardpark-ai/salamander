#!/usr/bin/env bash
# The project spawn (Thu Oct 15th 2026; lib/spawn.sh THE MANDATE and A PROJECT AGENT, lib/common.sh THE PROJECT
# SPAWN'S CHECKS, lib/op.sh the spawn verb and THE MANDATE'S TRANSPORT): `spawn NAME --project <page key> --role front|back
# [--mandate FILE|TEXT] [--lane L]`, the one path a web request or `sala op spawn` takes to make a project agent's session.
# What is checked guards a session from being made wrong or unregistered, never the wording of a line: the argument matrix
# refused before anything is asked or made; a missing page (exit 4, `NO-PAGE:`), a "cannot tell" (refused, never fail-open,
# unlike a plain spawn, which keeps its fail-open) and a name not on THAT page's agents map (exit 3, the `REGISTER:` line and the
# `post project-agent` command with the name, the role, front or back and the mandate's first line cut to 70 characters and
# shell-quoted, never an `ADD-TO-PAGE:` block or a page edit — the page's keeper asked once by one stackshot message carrying
# the same command, not again within the hour, and never when a register hook owns registration); a name already live refused with no message; `--dry-run` making, recording and
# calling nothing; the real spawn of a front agent (the orientation line typed with the marker and the absolute path, waiting
# for a confirmation) and of a back agent (starting on it; nobody confirms), the lane row recorded for `--lane`, the register
# hook's arguments and environment, a hook that fails leaving the spawn done; through the queue: the shape refusals with
# nothing queued and no mandate file left, the plan, a TEXT mandate written to its file at queue time (newlines, quotes,
# Japanese, a leading dash kept as bytes) and a FILE passed as it is, a refusal at queue time (exit 3, the register command unindented,
# nothing queued, the keeper asked with who heard and the owner's words), the end to end (queued → the unit → the session up reading
# its file → done, the file kept), a conflict on one name, and a line removed between the queue and the run → stuck with no
# claude -p; and, for the side conversation (`spawn NAME --side`), the queue's side: its shape refused at queue time, the plan, the marker's
# arguments, a conflict, the retire gate on a side session without its write-up (the session itself is tests/side.sh); the start directory
# (a back agent with no --cwd starts in the directory SALA_BACK_CWD names, else $HOME when it is unset, and refused when it names a directory that is missing; --cwd wins;
# front, plain and side keep $HOME; the dry run and the pane map show it), and the surface (`--surface slack`: a front agent that answers on Slack starts in the directory
# SALA_SLACK_CWD names, refused with a message naming the key when it is unset or missing, refused with a back role or a side session or a bad value; its row carries
# surface: slack, spawn --list and sessions mark it, the register command carries --surface slack; through the queue: the shape, the plan, the marker's arguments) and the launch line's Enter (a pane that shows ble.sh's
# "-- MULTILINE --" banner gets one C-j). pages.py is a stub (SALA_AGENT_CHECK_SCRIPT), the stackshot message a stub (SALA_SPAWN_ASK_CMD), the register
# hook a stub, systemd-run / systemctl stubs, the claude -p a stub (never the API), Slack a file; isolated HOME, a private
# tmux socket, the compiled fake claude. No real session, page, message or unit is touched.
# Usage: bash tests/spawn.sh   (exit 0 = pass; ~60 s)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_MASTER SALA_SET SALA_SET_SELF SALA_RECYCLE SALA_RETRY_WORKER SALA_LOCK_WHO SALA_LOCK_WAIT SALA_RELAUNCH_KIND \
      SALA_FLEET_HOSTS SALA_CGROUP_FILE SALA_OP_QUEUE SALA_OP_REBOOT SALA_OP_STUCK SALA_REBOOT_HOOKS SALA_NO_RELAUNCH SALA_SPAWN_REGISTER \
      SALA_AGENT_CHECK SALA_AGENT_CHECK_SCRIPT SALA_BACK_CWD SALA_SLACK_CWD SALA_SPAWN_ASK_CMD SALA_SPAWN_ASK_EVERY SALA_OP_FROM SALA_OP_WORDS SALA_OP_ID SALA_OP_PLAN
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"   # short timings, ok/bad/waitfor, fake_up, tmux_socket_rm; the lane variables unset
# the made-up fleet these checks were written against: three scopes, so a page the project record does not know is named <scope>-<slug>
# (tests/neutral-defaults.sh covers none set)
export SALA_SCOPES="example demo gamma" SALA_DEFAULT_SCOPE=gamma SALA_PAGE_DIRS="projects example"
TD=""
cleanup() {   # the trap is set before the folder is made (tests/neutral-defaults.sh); SOCK and T come later
    local p
    if [ -n "${SOCK:-}" ]; then $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1; fi
    if [ -n "$TD" ]; then
        for p in $(pgrep -x claude); do [ "$TD/.local/share/claude/versions/9.9.9" -ef "/proc/$p/exe" ] && kill -9 "$p" 2>/dev/null; done
        rm -rf "$TD" 2>/dev/null
    fi; true
}; trap cleanup EXIT
TD=$(mktemp -d "${TMPDIR:-/tmp}/sala-spawn.XXXXXX")
exec 8< "$TD"; flock -n 8 2>/dev/null   # systemd-tmpfiles' ageing skips a directory held with flock
export HOME="$TD"; export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect" "$HOME/pages/projects" "$HOME/pages/example"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
mkdir -p "$HOME/.local/share/claude/versions"; cc -o "$HOME/.local/share/claude/versions/9.9.9" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (an EXIT trap may not exist yet here)
ln -s "$HOME/.local/share/claude/versions/9.9.9" "$HOME/.local/bin/claude"
LAUNCHES="$HOME/systemd-run.txt"
cat > "$HOME/.local/bin/systemd-run" <<'EOF'
#!/bin/bash
# the stub unit (tests/op.sh): records the line; a sala-op-<id> launch runs its command detached in the queue's cgroup,
# unless $HOME/norun exists (a runner that never runs)
echo "$*" >> "$HOME/systemd-run.txt"
case " $* " in *" --on-active="*) exit 0;; esac
case "$*" in *--unit=sala-op-*) ;; *) exit 0;; esac
case "$*" in *-stuck\ *) ;; *) [ -e "$HOME/norun" ] && exit 0;; esac
cmd="${@: -1}"; SALA_CGROUP_FILE="$HOME/op-unit.cgroup" setsid bash -c "$cmd" </dev/null >/dev/null 2>&1 &
exit 0
EOF
echo "0::/user.slice/user-$EUID.slice/user@$EUID.service/app.slice/sala-op-1760000000-1.service" > "$HOME/op-unit.cgroup"
cat > "$HOME/.local/bin/systemctl" <<'EOF'
#!/bin/bash
echo "$*" >> "$HOME/systemctl.txt"
case "$*" in *is-active*) echo inactive; exit 3 ;; *is-system-running*) echo running; exit 0 ;; *) exit 0 ;; esac
EOF
cat > "$HOME/fake-helper" <<'EOF'
#!/bin/bash
echo "run $(date +%s)" >> "$HOME/helper-runs.txt"; echo "SALA-OP: stuck the test helper does nothing"
EOF
# the stub pages.py (stackshot's; SALA_AGENT_CHECK_SCRIPT): `resolve <key>` answers from $HOME/pages/<key>.md; `agent-listed <name>`
# from $HOME/listed.txt (key<TAB>name<TAB>mandate) with pages.py's own lines; orphan-* names get its "nothing to check";
# $HOME/pages-cannot-tell makes both unable to tell, $HOME/pages-listed-cannot-tell only agent-listed; every call is logged
cat > "$HOME/fake-pages.py" <<'PY'
import os, sys
home = os.environ["HOME"]; cmd = sys.argv[1]; arg = sys.argv[2] if len(sys.argv) > 2 else ""
open(home + "/pages-calls.txt", "a").write(" ".join(sys.argv[1:]) + "\n")
if os.path.exists(home + "/pages-cannot-tell"):
    if cmd == "resolve": print(arg, None); sys.exit(1)
    print("cannot tell: no brain mirror on this machine"); sys.exit(2)
if cmd == "resolve":
    ex = os.path.exists(f"{home}/pages/{arg}.md"); print(arg, ex); sys.exit(0 if ex else 1)
if cmd == "agent-listed":
    if os.path.exists(home + "/pages-listed-cannot-tell"): print("cannot tell: no brain mirror on this machine"); sys.exit(2)
    listed = {}
    try:
        for ln in open(home + "/listed.txt"):
            if ln.strip(): k, n, m = ln.rstrip("\n").split("\t"); listed[n] = (k, m)
    except FileNotFoundError: pass
    if arg in listed: print(f"listed on {listed[arg][0]}: {listed[arg][1]}"); sys.exit(0)
    if arg.startswith("orphan-"): print("no project page for this name: nothing to check"); sys.exit(0)
    if arg.startswith("oldorphan-"): print("no steward page for this name: nothing to check"); sys.exit(0)   # stackshot before Fri Oct 16th 2026
    if arg.startswith("oldfmt-"):   # the refusal as stackshot worded it before Fri Oct 16th 2026
        print(f"not listed: {arg} is not under `agents:` on projects/foo (steward gamma-foo). The steward adds the line `{arg}: <mandate>` there first, then the session can be made."); sys.exit(3)
    print(f"not listed: {arg} is not under `agents:` on projects/foo (the page whose `display-name:` line is gamma-foo). The line `{arg}: <mandate>` has to be added there first (ask the project's -main agent), then the session can be made."); sys.exit(3)
sys.exit(1)
PY
ASKS="$HOME/ask-log.txt"   # the stub stackshot message (SALA_SPAWN_ASK_CMD): its arguments, one record per call, '%%' between them
printf '#!/bin/bash\n{ printf "%%s\\n" "$@"; echo "%%%%"; } >> "$HOME/ask-log.txt"\n' > "$HOME/fake-ask"
cat > "$HOME/fake-register" <<'EOF'
#!/bin/bash
# the stub register hook (SALA_SPAWN_REGISTER): its four arguments and the SALA_SPAWN_* environment; $HOME/reg-fail makes it exit 7
printf '%s\n' "$@" > "$HOME/reg-args.txt"
env | grep '^SALA_SPAWN_' | sort > "$HOME/reg-env.txt"
[ -e "$HOME/reg-fail" ] && exit 7
exit 0
EOF
chmod +x "$HOME/.local/bin/systemd-run" "$HOME/.local/bin/systemctl" "$HOME/fake-helper" "$HOME/fake-ask" "$HOME/fake-register"
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.log"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="{ cat; echo '%%'; } >> $POSTS"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off
export SALA_LIMIT_ALERT=off SALA_LIMIT_RESUME=off SALA_STUCK_POST=off
export SALA_AGENT_CHECK_SCRIPT="$HOME/fake-pages.py" SALA_SPAWN_ASK_CMD="$HOME/fake-ask"   # the check is ON: the stub answers for pages.py
export SALA_OP_CLAUDE="$HOME/fake-helper" SALA_OP_POLL=1 SALA_OP_LOCK_WAIT=5 SALA_OP_SWEEP_WAIT=60 SALA_OP_SETTLE_WAIT=60 SALA_OP_STUCK_TIME=30 SALA_OP_HELPER_CWD="$HOME"
SALA="$ROOT/bin/salamander"; SOCK="sala-spawn-$$"; T="tmux -L $SOCK -f /dev/null"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux
. "$ROOT/lib/common.sh"
OPS="$SALA_STATE_DIR/ops"; DONE="$OPS/done"; MANDATES="$SALA_STATE_DIR/mandates"; SPAWNLOG="$HOME/.claude/salamander-spawn.log"
TYPED="$HOME/typed.log"   # every line that reaches a fake's composer (FAKE_TYPED_LOG), marker and all
run() { OUT=$("$SALA" spawn "$@" 2>&1); RC=$?; }
mval() { local f="$OPS/$1.op"; [ -f "$f" ] || f="$DONE/$1.op"; awk -F= -v k="$2" '$1==k {print substr($0, length(k)+2); exit}' "$f" 2>/dev/null; }
mvals() { local f="$OPS/$1.op"; [ -f "$f" ] || f="$DONE/$1.op"; awk -F= -v k="$2" '$1==k {print substr($0, length(k)+2)}' "$f" 2>/dev/null; }
queued() { ls "$OPS"/*.op 2>/dev/null | wc -l; }
nmandates() { ls "$MANDATES"/*.md 2>/dev/null | wc -l; }
tick() { "$SALA" watch --ops >/dev/null 2>&1; }
asks() { grep -c '^%%$' "$ASKS" 2>/dev/null || echo 0; }
nask() { awk -v RS='%%\n' -v h="agent '$1' of" 'index($0, h) {n++} END {print n+0}' "$ASKS" 2>/dev/null; }   # <name> → how many messages asked for it
ask() { awk -v RS='%%\n' -v h="agent '$1' of" 'index($0, h) {printf "%s", $0; exit}' "$ASKS" 2>/dev/null; }   # <name> → the first message asking for it
waitask() { waitfor "[ \"\$(nask $1)\" -ge 1 ]" 20; }   # the message is sent detached: wait for it, never a fixed sleep
runs() { grep -c '^run' "$HOME/helper-runs.txt" 2>/dev/null || echo 0; }
pcalls() { grep -c . "$HOME/pages-calls.txt" 2>/dev/null || echo 0; }
sessions() { tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -v '^keep-alive$' | paste -sd' ' -; }
fakeenv() { tmux set-environment -g FAKE_SESSION_ID "$1"; tmux set-environment -g FAKE_NAME "$2"; }   # what the next spawned fake claude registers as
list() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$HOME/listed.txt"; }   # <page key> <name> <mandate>: the stub's agents map
unlist() { sed -i "/\t$1\t/d" "$HOME/listed.txt"; }
cmdline() { grep -m1 '^python3 ~/stackshot/stackshot/fleet/client.py post project-agent ' <<< "$1"; }   # <output> → the register command, the stdout line at column 0 (the refusal's own copy on stderr is not at column 0)
noaddpage() { ! grep -qE 'ADD-TO-PAGE|^agents:|^ +background:|Add the line|add the line|Please add this' <<< "$1"; }   # <text> → true when it holds no page-edit instruction or YAML block
touch "$HOME/pages/projects/foo.md" "$HOME/pages/projects/demo-docs.md" "$HOME/pages/example/ops.md"
tmux new-session -d -s keep-alive   # the server the spawns land on, with the fake's environment
tmux set-environment -g FAKE_LOG "$FAKE_LOG"; tmux set-environment -g FAKE_TYPED_LOG "$TYPED"
BACKD="$HOME/back-brief"; mkdir -p "$BACKD"; export SALA_BACK_CWD="$BACKD"   # the background brief's directory: a back agent with no --cwd starts here
N48=$(printf '%*s' 48 '' | tr ' ' a); N49="${N48}a"; list projects/foo "$N48" "a long name"

echo "== the argument matrix: refused before anything is asked or made (exit 1, no pages.py call, no session)"
run x --role back; [ "$RC" = 1 ] && has "$OUT" "--role needs --project" && ok "--role without --project" || bad "role alone: rc=$RC — $OUT"
run x --project projects/foo; [ "$RC" = 1 ] && has "$OUT" "--project needs --role front or --role back" && ok "--project without --role" || bad "project alone: rc=$RC — $OUT"
run x --project projects/foo --role sideways; [ "$RC" = 1 ] && has "$OUT" "--role takes front or back" && ok "--role sideways" || bad "role sideways: rc=$RC — $OUT"
run x --project projects/foo --role back; [ "$RC" = 1 ] && has "$OUT" "a back agent needs --mandate" && ok "a back agent without a mandate" || bad "back no mandate: rc=$RC — $OUT"
for n in Foo_Bar -foo foo- "a.b" "$N49"; do run "$n" --project projects/foo --role front --dry-run; [ "$RC" = 1 ] && { has "$OUT" "is not an agent name" || has "$OUT" "invalid session name" || has "$OUT" "unknown first argument"; } && ok "name '${n:0:12}…' refused" || bad "name '$n': rc=$RC — $OUT"; done
run "$N48" --project projects/foo --role front --dry-run; [ "$RC" = 0 ] && has "$OUT" "[dry-run] would spawn '$N48'" && ok "a 48-character name passes the name rule (SALA_AGENT_NAME_MAX)" || bad "48 chars: rc=$RC — $OUT"
for k in Projects/foo projects/Foo foo projects/ other/foo projects/-foo "projects/foo bar"; do run x --project "$k" --role front; [ "$RC" = 1 ] && has "$OUT" "is not a page key" && ok "page key '$k' refused" || bad "key '$k': rc=$RC — $OUT"; done
run x --project projects/foo --role front --mandate ''; [ "$RC" = 1 ] && has "$OUT" "not an empty argument" && ok "--mandate '' refused" || bad "empty mandate: rc=$RC — $OUT"
run x --project projects/foo --role front --brief "$HOME/nope.md"; [ "$RC" = 1 ] && has "$OUT" "brief not readable" && ok "--brief of no such file refused (a file only)" || bad "brief nope: rc=$RC — $OUT"
run x --project projects/foo --role front --lane nope --dry-run; [ "$RC" = 1 ] && has "$OUT" "is not a lane" && ok "--lane nope refused" || bad "lane nope: rc=$RC — $OUT"
run x --project projects/foo --role front --effort huge --dry-run; [ "$RC" = 1 ] && has "$OUT" "invalid --effort" && ok "--effort huge refused" || bad "effort: rc=$RC — $OUT"
[ "$(pcalls)" = 2 ] && grep -q "^agent-listed $N48$" "$HOME/pages-calls.txt" && [ -z "$(sessions)" ] && sleep 1 && [ "$(asks)" = 0 ] && ok "pages.py asked only for the 48-character name (the one that reached the page: resolve, agent-listed); nobody asked, no session made" || bad "pages calls: $(slurp "$HOME/pages-calls.txt"); asks=$(asks); sessions: $(sessions)"
: > "$HOME/pages-calls.txt"

echo "== the page: missing → exit 4 and NO-PAGE:; cannot tell (no brain, no pages.py) → refused, never fail-open; a plain spawn keeps its fail-open"
run gamma-nope-main --project projects/nope --role front --dry-run
[ "$RC" = 4 ] && grep -qx 'NO-PAGE: projects/nope' <<< "$OUT" && has "$OUT" "ask a session with gbrain" && ok "no page: exit 4, NO-PAGE: projects/nope, the pointer to a session with gbrain" || bad "no page: rc=$RC — $OUT"
[ "$(asks)" = 0 ] && ok "no page: nobody asked (there is no keeper to ask)" || bad "asked: $(<"$ASKS")"
touch "$HOME/pages-cannot-tell"; run gamma-foo-main --project projects/foo --role front --dry-run; rm -f "$HOME/pages-cannot-tell"
[ "$RC" = 1 ] && has "$OUT" "cannot tell whether the page projects/foo exists" && ok "resolve cannot tell: refused (exit 1)" || bad "cannot tell page: rc=$RC — $OUT"
touch "$HOME/pages-listed-cannot-tell"; run gamma-foo-main --project projects/foo --role front --dry-run; rm -f "$HOME/pages-listed-cannot-tell"
[ "$RC" = 1 ] && has "$OUT" "cannot tell whether 'gamma-foo-main' is on the agents map of projects/foo" && ok "agent-listed cannot tell: refused (exit 1)" || bad "cannot tell listed: rc=$RC — $OUT"
SALA_AGENT_CHECK_SCRIPT="$HOME/nowhere.py" run gamma-foo-main --project projects/foo --role front --dry-run
[ "$RC" = 1 ] && has "$OUT" "no pages.py on this box" && ok "no pages.py anywhere: a project spawn is refused" || bad "no pages.py: rc=$RC — $OUT"
SALA_AGENT_CHECK_SCRIPT="$HOME/nowhere.py" run plain-x --dry-run
[ "$RC" = 0 ] && has "$OUT" "[dry-run] would spawn 'plain-x'" && ok "no pages.py anywhere: a plain spawn passes as before (agent_unlisted fails open)" || bad "plain fail-open: rc=$RC — $OUT"
[ "$(asks)" = 0 ] && [ -z "$(sessions)" ] && ok "none of these asked anyone or made a session" || bad "asks=$(asks) sessions: $(sessions)"

echo "== SALA_STACKSHOT_DIR: the default pages.py comes from it — unset is ~/stackshot, a directory is used, empty is none; an explicit script wins"
mkdir -p "$HOME/ss" "$HOME/stackshot"; cp "$HOME/fake-pages.py" "$HOME/ss/pages.py"; cp "$HOME/fake-pages.py" "$HOME/stackshot/pages.py"
run gamma-foo-main --project projects/foo --role front --dry-run; BASE_RC="$RC"; BASE_OUT="$OUT"          # the explicit stub script: the baseline answer
OUT=$(env -u SALA_AGENT_CHECK_SCRIPT -u SALA_STACKSHOT_DIR "$SALA" spawn gamma-foo-main --project projects/foo --role front --dry-run 2>&1); RC=$?
[ "$RC" = "$BASE_RC" ] && ! has "$OUT" "no pages.py on this box" && ok "unset: ~/stackshot/pages.py answers as the explicit script did" || bad "unset: rc=$RC (want $BASE_RC) — $OUT"
OUT=$(env -u SALA_AGENT_CHECK_SCRIPT SALA_STACKSHOT_DIR="$HOME/ss" "$SALA" spawn gamma-foo-main --project projects/foo --role front --dry-run 2>&1); RC=$?
[ "$RC" = "$BASE_RC" ] && ! has "$OUT" "no pages.py on this box" && ok "a directory: its pages.py answers" || bad "dir: rc=$RC (want $BASE_RC) — $OUT"
OUT=$(env -u SALA_AGENT_CHECK_SCRIPT SALA_STACKSHOT_DIR= "$SALA" spawn gamma-foo-main --project projects/foo --role front --dry-run 2>&1); RC=$?
[ "$RC" = 1 ] && has "$OUT" "no pages.py on this box" && ok "empty: no pages.py, a project spawn refused (still fail-closed)" || bad "empty: rc=$RC — $OUT"
OUT=$(env -u SALA_AGENT_CHECK_SCRIPT SALA_STACKSHOT_DIR= "$SALA" spawn plain-x --dry-run 2>&1); RC=$?
[ "$RC" = 0 ] && has "$OUT" "[dry-run] would spawn 'plain-x'" && ok "empty: a plain spawn still passes (fail-open)" || bad "empty plain: rc=$RC — $OUT"
OUT=$(SALA_STACKSHOT_DIR= "$SALA" spawn gamma-foo-main --project projects/foo --role front --dry-run 2>&1); RC=$?
[ "$RC" = "$BASE_RC" ] && ok "an explicit SALA_AGENT_CHECK_SCRIPT wins over an empty directory" || bad "explicit: rc=$RC (want $BASE_RC) — $OUT"
rm -rf "$HOME/ss" "$HOME/stackshot"

echo "== not listed: exit 3, the register command (no page edit), the keeper asked once by one message and not again within the hour"
run gamma-foo-main --project projects/foo --role front --dry-run
[ "$RC" = 3 ] && has "$OUT" "'gamma-foo-main' is not on the agents map of projects/foo" && ok "a front agent not listed: exit 3" || bad "unlisted front: rc=$RC — $OUT"
[ "$(sed -n '/^REGISTER: /,$p' <<< "$OUT" | grep -v '^   ' | paste -sd'|' -)" = 'REGISTER: projects/foo|python3 ~/stackshot/stackshot/fleet/client.py post project-agent projects/foo gamma-foo-main --role <role> --front --mandate "<one line>"' ] && ok "stdout: REGISTER: projects/foo, then the post project-agent command (project, name, role, --front, the mandate placeholder)" || bad "block: $OUT"
noaddpage "$OUT" && has "$OUT" "Register it, then spawn again: python3 ~/stackshot/stackshot/fleet/client.py post project-agent projects/foo gamma-foo-main" && ok "the refusal names only the register command: no ADD-TO-PAGE, no YAML block, no instruction to edit the page" || bad "page edit in the refusal: $OUT"
waitask gamma-foo-main && A=$(ask gamma-foo-main) && [ "$(sed -n 1p <<< "$A")" = "projects/foo" ] && grep -q -- '^--sender$' <<< "$A" && grep -qx 'sala spawn' <<< "$A" \
    && has "$A" "A new front agent 'gamma-foo-main' of projects/foo was asked for" && [ "$(cmdline "$A")" = 'python3 ~/stackshot/stackshot/fleet/client.py post project-agent projects/foo gamma-foo-main --role <role> --front --mandate "<one line>"' ] && noaddpage "$A" && ok "one stackshot message to the page key, sender 'sala spawn', the register command inside and no page edit" || bad "ask: $(slurp "$ASKS")"
run gamma-foo-main --project projects/foo --role front --dry-run
[ "$RC" = 3 ] && has "$OUT" "not again within 60 min" && sleep 1 && [ "$(nask gamma-foo-main)" = 1 ] && ok "the same name again: refused again, the keeper not asked again" || bad "second: rc=$RC asks=$(nask gamma-foo-main) — $OUT"
L77="Title: $(printf '%*s' 70 '' | tr ' ' x)"
run gamma-foo-worker --project projects/foo --role back --mandate "# $L77"$'\n'"second line" --dry-run
[ "$RC" = 3 ] && [ "$(sed -n '/^REGISTER: /,$p' <<< "$OUT" | grep -v '^   ' | sed -n 1p)" = "REGISTER: projects/foo" ] && cmdline "$OUT" | grep -q -- ' gamma-foo-worker --role <role> --back --mandate ' && noaddpage "$OUT" && ok "a back agent: the command says --back" || bad "back block: $OUT"
[ "$(cmdline "$OUT")" = "python3 ~/stackshot/stackshot/fleet/client.py post project-agent projects/foo gamma-foo-worker --role <role> --back --mandate \"${L77:0:70}\"" ] && ok "the mandate line: the heading's # stripped, cut to 70 characters, double-quoted as the command's --mandate" || bad "value: '$(cmdline "$OUT")'"
waitask gamma-foo-worker && has "$(ask gamma-foo-worker)" "--mandate <the mandate>" && [ "$(cmdline "$(ask gamma-foo-worker)")" = "python3 ~/stackshot/stackshot/fleet/client.py post project-agent projects/foo gamma-foo-worker --role <role> --back --mandate \"${L77:0:70}\"" ] && ok "a second name: its own message with its command, the mandate's place in the words to say" || bad "worker ask: $(ask gamma-foo-worker)"
K75=$(python3 -c 'print("あ"*75)')
run gamma-foo-k --project projects/foo --role back --mandate "$K75" --dry-run
V=$(cmdline "$OUT" | sed 's/.* --mandate "\(.*\)"$/\1/'); [ "$RC" = 3 ] && [ "$(python3 -c 'import sys; print(len(sys.argv[1]))' "$V")" = 70 ] && [ "$V" = "${K75:0:70}" ] && ok "a Japanese line is cut at 70 characters, never mid-character" || bad "korean: '$V'"
run gamma-foo-d --project projects/foo --role back --mandate "- a list item" --dry-run; [ "$(cmdline "$OUT" | sed 's/.* --mandate //')" = '"- a list item"' ] && ok "a leading dash: kept inside the quotes" || bad "dash: $OUT"
run gamma-foo-p --project projects/foo --role back --mandate "watch the queue" --dry-run; [ "$(cmdline "$OUT" | sed 's/.* --mandate //')" = '"watch the queue"' ] && ok "a plain line: in double quotes" || bad "plain: $OUT"
run gamma-foo-q --project projects/foo --role back --mandate 'say "hi" to $HOME and `id`' --dry-run
Q=$(cmdline "$OUT" | sed 's/.* --mandate //'); [ "$RC" = 3 ] && [ "$Q" = '"say \"hi\" to \$HOME and \`id\`"' ] && [ "$(eval "printf %s $Q")" = 'say "hi" to $HOME and `id`' ] && ok "a quote, a dollar sign and a backtick in the mandate: escaped, the shell reads the original back and runs nothing" || bad "shell-special: '$Q'"
waitask gamma-foo-k && waitask gamma-foo-d && waitask gamma-foo-p && [ "$(nask gamma-foo-k)$(nask gamma-foo-d)$(nask gamma-foo-p)" = 111 ] && ok "each name asked for once" || bad "asks: k=$(nask gamma-foo-k) d=$(nask gamma-foo-d) p=$(nask gamma-foo-p)"
SALA_OP_FROM=sala-test-h SALA_OP_WORDS="make a scout" run gamma-foo-scout --project projects/foo --role back --mandate "scout" --dry-run
waitask gamma-foo-scout && has "$(ask gamma-foo-scout)" "was asked for by sala-test-h (\"make a scout\")" && ok "who heard and the owner's words (SALA_OP_FROM, SALA_OP_WORDS) are in the message" || bad "from/words: $(ask gamma-foo-scout)"
SALA_SPAWN_REGISTER="$HOME/fake-register \"\$@\"" run gamma-foo-hooked --project projects/foo --role front --dry-run
[ "$RC" = 3 ] && has "$OUT" "REGISTER: projects/foo" && sleep 1 && [ "$(nask gamma-foo-hooked)" = 0 ] && grep -q "ask: not sent for projects/foo — SALA_SPAWN_REGISTER is configured" "$SPAWNLOG" && ok "with a register hook configured: refused with the command, nobody asked (registration is the hook's), logged" || bad "hook+unlisted: rc=$RC asks=$(nask gamma-foo-hooked) — $OUT"
SALA_SPAWN_ASK_CMD= run gamma-foo-quiet --project projects/foo --role front --dry-run
[ "$RC" = 3 ] && sleep 1 && [ "$(nask gamma-foo-quiet)" = 0 ] && grep -q "spawn gamma-foo-quiet: ask: not sent for projects/foo — SALA_SPAWN_ASK_CMD is empty" "$SPAWNLOG" && ok "SALA_SPAWN_ASK_CMD set empty: refused, nobody asked, logged" || bad "ask cmd empty: rc=$RC asks=$(nask gamma-foo-quiet) — $(grep gamma-foo-quiet "$SPAWNLOG")"
list projects/bar gamma-foo-main "another page's agent"
run gamma-foo-main --project projects/foo --role front --dry-run; [ "$RC" = 3 ] && has "$OUT" "REGISTER: projects/foo" && ok "listed on another page (projects/bar): not on this one — refused with the command" || bad "other page: rc=$RC — $OUT"
unlist gamma-foo-main
run orphan-x --project projects/foo --role front --dry-run; [ "$RC" = 3 ] && has "$OUT" "nothing to check" && has "$OUT" "REGISTER: projects/foo" && waitask orphan-x && ok "pages.py's 'no project page for this name: nothing to check' (exit 0): not on this page — refused with the command, the keeper asked" || bad "orphan: rc=$RC — $OUT"
run oldorphan-x --project projects/foo --role front --dry-run; [ "$RC" = 3 ] && has "$OUT" "nothing to check" && has "$OUT" "REGISTER: projects/foo" && waitask oldorphan-x && ok "the old 'no steward page … nothing to check' (exit 0) still counts as not on this page" || bad "old orphan: rc=$RC — $OUT"
[ -z "$(sessions)" ] && [ ! -f "$HOME/reg-args.txt" ] && [ ! -r "$SALA_LANES" ] && ok "none of the refusals made a session, called the hook or wrote a lane row" || bad "sessions: $(sessions) reg: $(slurp "$HOME/reg-args.txt")"
n=$(pcalls); SALA_AGENT_CHECK=off run gamma-foo-main --project projects/foo --role front --dry-run
[ "$RC" = 0 ] && [ "$(pcalls)" = "$n" ] && has "$OUT" "not checked (SALA_AGENT_CHECK=off)" && ok "SALA_AGENT_CHECK=off: no pages.py call, the dry run says so" || bad "check off: rc=$RC calls=$(pcalls) — $OUT"

echo "== listed: the dry run passes and makes, records and calls nothing; a name already live is refused with no message"
list projects/foo gamma-foo-main "Rowan's contact for foo"
run gamma-foo-main --project projects/foo --role front --dry-run
[ "$RC" = 0 ] && has "$OUT" "[dry-run] would spawn 'gamma-foo-main' as a front agent of projects/foo (on its agents map: Rowan's contact for foo) on the Ultra lane" && has "$OUT" "[dry-run] mandate: none" && has "$OUT" "nothing made, recorded or typed" && ok "listed, front, no mandate: the plan" || bad "dry run: rc=$RC — $OUT"
run gamma-foo-main --project projects/foo --role front --lane subscription-1 --mandate "$HOME/nope.md" --dry-run
[ "$RC" = 0 ] && has "$OUT" "on the Ultra lane (recorded)" && has "$OUT" "[dry-run] mandate: the text typed as the first message: $HOME/nope.md" && [ ! -r "$SALA_LANES" ] && ok "--lane subscription-1 --dry-run: the lane named as recorded, no row written; --mandate of no such file is text" || bad "dry lane: rc=$RC — $OUT / $(slurp "$SALA_LANES")"
[ -z "$(sessions)" ] && [ ! -f "$HOME/reg-args.txt" ] && [ ! -f "$SALA_SIDECAR" ] && ok "the dry runs made no session, no pane-map row, no hook call" || bad "sessions: $(sessions)"
run --project projects/foo --role front --dry-run; [ "$RC" = 0 ] && has "$OUT" "would spawn 'gamma-foo-main'" && ok "no NAME with --project: the suggested name (gamma-foo-main) is used" || bad "no name: rc=$RC — $OUT"
tmux new-session -d -s gamma-foo-taken "sleep 300"
n=$(asks); c=$(pcalls); run gamma-foo-taken --project projects/foo --role front --dry-run
[ "$RC" = 1 ] && has "$OUT" "tmux session 'gamma-foo-taken' already exists" && sleep 1 && [ "$(asks)" = "$n" ] && [ "$(pcalls)" = "$c" ] && ok "a tmux session of the name: refused before any page is asked, nobody messaged" || bad "live tmux: rc=$RC calls=$(pcalls)/$c — $OUT"
tmux kill-session -t =gamma-foo-taken
tmux new-session -d -s other-pane -c "$HOME" -e FAKE_SESSION_ID="$(uuid 9)" -e FAKE_NAME=gamma-foo-live -e FAKE_LOG="$FAKE_LOG"; tmux send-keys -t other-pane 'claude' Enter
fake_up gamma-foo-live || bad "the fake under gamma-foo-live did not come up"
run gamma-foo-live --project projects/foo --role front --dry-run
[ "$RC" = 1 ] && has "$OUT" "'gamma-foo-live' is already the name of a live session" && sleep 1 && [ "$(asks)" = "$n" ] && [ "$(pcalls)" = "$c" ] && ok "a running claude registered under the name (another pane): refused before any page is asked, nobody messaged" || bad "live registry: rc=$RC calls=$(pcalls)/$c — $OUT"
tmux kill-session -t =other-pane

echo "== --suggest-name: the convention the pages follow (a suggestion the web form shows, not a check)"
run --suggest-name --project projects/demo-docs --role front --new; [ "$RC" = 0 ] && [ "$OUT" = demo-docs-main ] && ok "projects/demo-docs front, a new project (--new) → demo-docs-main" || bad "suggest demo: $OUT"
run --suggest-name --project example/ops --role back; [ "$RC" = 0 ] && grep -qE '^example-ops-[a-z]+$' <<< "$OUT" && ok "example/ops back → example-ops-<word> ($OUT)" || bad "suggest example: $OUT"
run --suggest-name --project projects/harbor-room-b --role front --new; [ "$RC" = 0 ] && [ "$OUT" = gamma-harbor-room-b-main ] && ok "projects/harbor-room-b front, a new project → gamma-harbor-room-b-main" || bad "suggest harbor: $OUT"
run --suggest-name --project projects/harbor-room-b --role front; [ "$RC" = 0 ] && grep -qE '^gamma-harbor-room-b-[a-z]+$' <<< "$OUT" && [ "$OUT" != gamma-harbor-room-b-main ] && ok "the same without --new and with no project record: a word, never -main ($OUT)" || bad "suggest no record: rc=$RC — $OUT"
run --suggest-name --project projects/foo; [ "$RC" = 1 ] && ok "--suggest-name without --role: refused" || bad "suggest no role: rc=$RC — $OUT"

echo "== --suggest-name never names a taken name; -main only for a project with no agent yet; the prefix is the project record's"
# projects/wiki: its agents are wiki-*, and the page key alone would say gamma-wiki (the wrong prefix)
SUGREC="$HOME/sugg-record.json"
python3 - "$SUGREC" <<'PY'
import datetime, json, sys
def ag(front): return {"front": front, "role": "x", "mandate_line": "m"}
P = {"projects/wiki": {"wiki-main": ag(True), "wiki-builder": ag(False), "wiki-hosting": ag(False)},
     "projects/empty": {}, "example/duo": {"example-duo-builder": ag(False), "example-duo-librarian": ag(False)}, "example/solo": {"example-solo-builder": ag(False)},
     "projects/empty2": {}, "projects/other": {"gamma-empty2-main": ag(True)},
     "projects/full": {"gamma-full-main": ag(True), **{f"gamma-full-{w}": ag(False) for w in ("fox", "lark", "wren", "moss", "ember")}}}
projects = {f"prj_{i:08x}": {"id": f"prj_{i:08x}", "key": k, "keeper": "k", "agents": a} for i, (k, a) in enumerate(P.items(), 1)}
json.dump({"schema": 1, "generated": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "projects": projects,
           "by_key": {p["key"]: i for i, p in projects.items()}}, open(sys.argv[1], "w"))
PY
sugg() { SALA_PROJECT_RECORD="$SUGREC" run --suggest-name "$@"; }
bad_n=0; for i in $(seq 1 12); do sugg --project projects/wiki --role front; { [ "$RC" = 0 ] && grep -qE '^wiki-[a-z]+$' <<< "$OUT" && [ "$OUT" != wiki-main ]; } || bad_n=$((bad_n+1)); done
[ "$bad_n" = 0 ] && ok "projects/wiki front (it has agents): wiki-<word>, the record's prefix (not gamma-wiki), never -main, 12 runs" || bad "wiki front: $bad_n of 12 wrong, last: rc=$RC — $OUT"
sugg --project projects/wiki --role back; [ "$RC" = 0 ] && grep -qE '^wiki-[a-z]+$' <<< "$OUT" && ok "projects/wiki back: wiki-<word> ($OUT)" || bad "wiki back: rc=$RC — $OUT"
sugg --project projects/empty --role front; [ "$RC" = 0 ] && [ "$OUT" = gamma-empty-main ] && ok "a project with no agent yet: its first front agent is -main (gamma-empty-main)" || bad "empty front: rc=$RC — $OUT"
sugg --project projects/empty --role back; [ "$RC" = 0 ] && grep -qE '^gamma-empty-[a-z]+$' <<< "$OUT" && [ "$OUT" != gamma-empty-main ] && ok "a back agent is never -main ($OUT)" || bad "empty back: rc=$RC — $OUT"
tmux new-session -d -s gamma-empty-main "sleep 300"
sugg --project projects/empty --role front; [ "$RC" = 0 ] && grep -qE '^gamma-empty-[a-z]+$' <<< "$OUT" && [ "$OUT" != gamma-empty-main ] && ok "-main live as a tmux session: a word instead ($OUT)" || bad "empty front, main live: rc=$RC — $OUT"
tmux kill-session -t =gamma-empty-main
sugg --project projects/empty2 --role front; [ "$RC" = 0 ] && grep -qE '^gamma-empty2-[a-z]+$' <<< "$OUT" && [ "$OUT" != gamma-empty2-main ] && ok "-main listed on another project's agents map: a word instead ($OUT)" || bad "empty2 front: rc=$RC — $OUT"
sugg --project example/duo --role front; [ "$RC" = 0 ] && grep -qE '^example-duo-[a-z]+$' <<< "$OUT" && ok "no -main agent: the prefix all its agents share (example-duo)" || bad "duo: rc=$RC — $OUT"
sugg --project example/solo --role back; [ "$RC" = 0 ] && grep -qE '^example-solo-[a-z]+$' <<< "$OUT" && ok "one agent (example-solo-builder): its role part is cut (example-solo)" || bad "solo: rc=$RC — $OUT"
tmux new-session -d -s gamma-full-heron "sleep 300"; tmux new-session -d -s gamma-full-otter "sleep 300"
seen=""; bad_n=0; for i in $(seq 1 30); do sugg --project projects/full --role back; seen="$seen $OUT"; case "$OUT" in gamma-full-fox|gamma-full-lark|gamma-full-wren|gamma-full-moss|gamma-full-ember|gamma-full-heron|gamma-full-otter|gamma-full-main) bad_n=$((bad_n+1));; esac; done
[ "$bad_n" = 0 ] && ok "30 suggestions for a project with agents fox lark wren moss ember (map) and heron otter (tmux): none of them taken" || bad "taken words suggested ($bad_n):$seen"
tmux kill-session -t =gamma-full-heron; tmux kill-session -t =gamma-full-otter
SALA_PROJECT_RECORD="$SUGREC" run --suggest-name --project projects/newthing --role front --prefix demo-newthing --new
[ "$RC" = 0 ] && [ "$OUT" = demo-newthing-main ] && ok "--new --prefix on a project the record does not know: <prefix>-main" || bad "prefix new: rc=$RC — $OUT"
SALA_PROJECT_RECORD="$SUGREC" run --suggest-name --project projects/newthing --role front --prefix demo-newthing
[ "$RC" = 0 ] && grep -qE '^demo-newthing-[a-z]+$' <<< "$OUT" && [ "$OUT" != demo-newthing-main ] && ok "…without --new the unknown project gets a word, not -main ($OUT)" || bad "unknown, no --new: rc=$RC — $OUT"
tmux new-session -d -s demo-newthing-main "sleep 300"
SALA_PROJECT_RECORD="$SUGREC" run --suggest-name --project projects/newthing --role front --prefix demo-newthing --new
[ "$RC" = 0 ] && grep -qE '^demo-newthing-[a-z]+$' <<< "$OUT" && [ "$OUT" != demo-newthing-main ] && ok "…and a word when that -main is a live session ($OUT)" || bad "prefix new, taken: rc=$RC — $OUT"
tmux kill-session -t =demo-newthing-main
SALA_PROJECT_RECORD="$SUGREC" run --suggest-name --project projects/wiki --role front --prefix wk
[ "$RC" = 0 ] && grep -qE '^wk-[a-z]+$' <<< "$OUT" && ok "--prefix wins over the record's prefix ($OUT)" || bad "prefix over record: rc=$RC — $OUT"
SALA_PROJECT_RECORD=/nonexistent run --suggest-name --project projects/wiki --role front; [ "$RC" = 0 ] && grep -qE '^gamma-wiki-[a-z]+$' <<< "$OUT" && [ "$OUT" != gamma-wiki-main ] && ok "no record: the page key's convention for the prefix, but a word, never -main ($OUT)" || bad "no record: rc=$RC — $OUT"
SALA_PROJECT_RECORD=/nonexistent run --suggest-name --project projects/wiki --role front --new; [ "$RC" = 0 ] && [ "$OUT" = gamma-wiki-main ] && ok "no record and --new: gamma-wiki-main" || bad "no record, new: rc=$RC — $OUT"
python3 - "$SUGREC" "$HOME/sugg-stale.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["generated"] = "2020-01-01T00:00:00Z"; json.dump(d, open(sys.argv[2], "w"))
PY
SALA_PROJECT_RECORD="$HOME/sugg-stale.json" run --suggest-name --project projects/empty --role front; [ "$RC" = 0 ] && grep -qE '^gamma-empty-[a-z]+$' <<< "$OUT" && [ "$OUT" != gamma-empty-main ] && ok "a stale record (2020) is no ground for -main: a word ($OUT)" || bad "stale record: rc=$RC — $OUT"
# the real spawn with no NAME keeps the older rule: a front is <prefix>-main (the record's prefix when it knows the project), a back agent a word
SALA_PROJECT_RECORD="$SUGREC" run --project projects/wiki --role front --dry-run; [ "$RC" = 0 ] && has "$OUT" "would spawn 'wiki-main'" && ok "a real spawn with no NAME, front, project with agents: wiki-main (the older rule, the record's prefix), not a word that is off the map" || bad "real front, no name: rc=$RC — $OUT"
SALA_PROJECT_RECORD=/nonexistent run --project projects/foo --role front --dry-run; [ "$RC" = 0 ] && has "$OUT" "would spawn 'gamma-foo-main'" && ok "a real spawn with no NAME and no record: gamma-foo-main as before" || bad "real front, no record: rc=$RC — $OUT"
# --prefix long: -main needs room (prefix + 5 <= 48), the number fallback leaves no double dash
long="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"  # 45 characters: 45 + 5 > 48
SALA_PROJECT_RECORD=/nonexistent run --suggest-name --project projects/newthing --role front --prefix "$long" --new; [ "$RC" = 0 ] && grep -qE '^a+-[a-z]+$' <<< "$OUT" && [ "${#OUT}" -le 48 ] && ok "a prefix with no room for -main (45 + 5 > 48): a word ($OUT)" || bad "long prefix: rc=$RC — $OUT"
run --suggest-name --side --project projects/foo --new; [ "$RC" = 1 ] && has "$OUT" "--new goes with --suggest-name" && ok "--new with --side is refused" || bad "new side: rc=$RC — $OUT"
run gamma-foo-main --project projects/foo --role front --new --dry-run; [ "$RC" = 1 ] && has "$OUT" "--new goes with --suggest-name" && ok "--new without --suggest-name is refused" || bad "new alone: rc=$RC — $OUT"
run --suggest-name --project projects/foo --role front --prefix "Bad Prefix"; [ "$RC" = 1 ] && has "$OUT" "--prefix takes lowercase letters" && ok "a bad --prefix is refused" || bad "bad prefix: rc=$RC — $OUT"
run gamma-foo-main --project projects/foo --role front --prefix gamma-foo --dry-run; [ "$RC" = 1 ] && has "$OUT" "--prefix goes with --suggest-name" && ok "--prefix without --suggest-name is refused" || bad "prefix alone: rc=$RC — $OUT"

echo "== the spawn of a front agent with a file mandate (relative path): the orientation line typed with the marker, waiting for a confirmation; no hook → the page's line is the record"
printf '# Foo main\n\nthe mandate body\n' > "$HOME/m1.md"
fakeenv "$(uuid 11)" gamma-foo-main
OUT=$(cd "$HOME" && "$SALA" spawn gamma-foo-main --project projects/foo --role front --mandate m1.md --cwd "$HOME" 2>&1); RC=$?
[ "$RC" = 0 ] && has "$OUT" "✅ spawned 'gamma-foo-main'" && has "$OUT" "project : projects/foo — front agent (on its agents map: Rowan's contact for foo)" && tmux has-session -t =gamma-foo-main 2>/dev/null && ok "spawned: exit 0, the session up, the project line" || { bad "front spawn: rc=$RC — $OUT"; }
# the four typed-line waits below are 120 half-seconds, deadlines only (a held wait returns at once): on a CI runner none of these lines ever came
# typed_ctx prints the fake's state, stdin and pane (tests/lib.sh typed_diag) so the next failing log says why
waitfor "grep -qF \"$(uuid 11) $SALA_MSG_MARK Read $HOME/m1.md in full — that is your mandate for this session.\" '$TYPED'" 120 && ok "the orientation line: typed with the marker, the mandate's ABSOLUTE path (m1.md given relative to where spawn ran)" || bad "typed: $(typed_ctx "$TYPED" "$(uuid 11)")"
grep "^$(uuid 11) " "$TYPED" | grep -qF "Do not act on it until I confirm." && ok "a front agent waits for a confirmation" || bad "confirm wording: $(typed_ctx "$TYPED" "$(uuid 11)")"
[ "$(grep "^$(uuid 11) " "$TYPED" | grep -v "^$(uuid 11) /rename gamma-foo-main$" | grep -vcF "$(uuid 11) $SALA_MSG_MARK ")" = 0 ] && ok "every other line typed into it was a slash command (nothing of sala's passes as Rowan's)" || bad "typed into gamma-foo-main: $(typed_ctx "$TYPED" "$(uuid 11)")"
grep -q "^gamma-foo-main	$(uuid 11)	" "$SALA_SIDECAR" 2>/dev/null && ok "the pane map has its row (a reboot brings it back)" || bad "pane map: $(slurp "$SALA_SIDECAR")"
[ -z "$(lane_row gamma-foo-main)" ] && has "$OUT" "lane    : subscription-1 (the default;" && ok "no --lane: no lane row, the default named" || bad "lane: '$(lane_row gamma-foo-main)' — $OUT"
has "$OUT" "register: no hook configured (SALA_SPAWN_REGISTER) — the line on projects/foo is the record" && grep -q "spawn gamma-foo-main: spawn-register: no hook configured (SALA_SPAWN_REGISTER); front agent of projects/foo, mandate $HOME/m1.md" "$SPAWNLOG" && [ ! -f "$HOME/reg-args.txt" ] \
    && ok "no register hook (the default): the no-op said and logged, nothing run" || bad "register default: $OUT / $(<"$SPAWNLOG")"
has "$OUT" "mandate : $HOME/m1.md (waits for a confirmation)" && ok "the report names the mandate file" || bad "report: $OUT"

echo "== the spawn of a back agent with a file mandate and --lane subscription-1: starts on it (nobody confirms), the lane row recorded, the register hook's arguments and environment"
list projects/foo gamma-foo-worker "the queue's worker"; printf 'Worker: do the work\nmore\n' > "$HOME/m2.md"
fakeenv "$(uuid 12)" gamma-foo-worker
SALA_SPAWN_REGISTER="\"$HOME/fake-register\" \"\$@\"" run gamma-foo-worker --project projects/foo --role back --mandate "$HOME/m2.md" --lane subscription-1 --cwd "$HOME"
[ "$RC" = 0 ] && has "$OUT" "✅ spawned 'gamma-foo-worker'" && tmux has-session -t =gamma-foo-worker 2>/dev/null && ok "spawned: exit 0, the session up" || bad "back spawn: rc=$RC — $OUT"
waitfor "grep -qF \"$(uuid 12) $SALA_MSG_MARK Read $HOME/m2.md in full\" '$TYPED'" 120 && grep "^$(uuid 12) " "$TYPED" | grep -qF "Then start on it; nobody is waiting to confirm." && ok "a back agent's orientation line: starts on it, nobody is waiting to confirm (--role back implies --no-confirm)" || bad "back typed: $(typed_ctx "$TYPED" "$(uuid 12)")"
[ "$(lane_row gamma-foo-worker)" = subscription-1 ] && has "$OUT" "lane    : subscription-1 (recorded: every relaunch keeps it)" && ok "--lane subscription-1: the row recorded (every relaunch keeps it)" || bad "lane row: '$(lane_row gamma-foo-worker)' — $OUT"
[ "$(paste -sd'|' "$HOME/reg-args.txt" 2>/dev/null)" = "gamma-foo-worker|projects/foo|back|$HOME/m2.md" ] && ok "the hook's four arguments: name, page key, role, mandate file" || bad "reg args: $(slurp "$HOME/reg-args.txt")"
E=$(slurp "$HOME/reg-env.txt"); has "$E" "SALA_SPAWN_NAME=gamma-foo-worker" && has "$E" "SALA_SPAWN_PROJECT=projects/foo" && has "$E" "SALA_SPAWN_ROLE=back" && has "$E" "SALA_SPAWN_MANDATE_FILE=$HOME/m2.md" && has "$E" "SALA_SPAWN_MANDATE_LINE=Worker: do the work" \
    && has "$E" "SALA_SPAWN_UUID=$(uuid 12)" && has "$E" "SALA_SPAWN_LANE=subscription-1" && ok "its environment: SALA_SPAWN_NAME/PROJECT/ROLE/MANDATE_FILE/MANDATE_LINE/UUID/LANE" || bad "reg env: $E"
has "$OUT" "register: the hook ran (SALA_SPAWN_REGISTER)" && grep -q "spawn gamma-foo-worker: spawn-register: the hook ran" "$SPAWNLOG" && ok "the hook's run said and logged" || bad "hook ran: $OUT"
grep -q "^gamma-foo-worker	$(uuid 12)	" "$SALA_SIDECAR" && ok "the pane map has its row" || bad "pane map: $(<"$SALA_SIDECAR")"
sreg() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); r=[x for x in d["sessions"].values() if x["name"]==sys.argv[2]]; print(len(r), r[0]["project"], r[0]["role"], r[0]["lane"], r[0]["transcripts"][0]["id"])' "$SALA_SESSIONS_FILE" "$1" 2>&1; }
[ "$(sreg gamma-foo-main)" = "1 projects/foo front None $(uuid 11)" ] && [ "$(sreg gamma-foo-worker)" = "1 projects/foo back subscription-1 $(uuid 12)" ] && ok "the session registry's rows carry project, role and the recorded lane (board#33, phase 1)" || bad "registry: $(sreg gamma-foo-main) / $(sreg gamma-foo-worker)"

echo "== the spawn of a front agent with a text mandate (--prompt) and a failing hook: the text typed as the first message, the hook's failure one ⚠ line, the spawn done"
list projects/foo gamma-foo-press "press"; rm -f "$HOME/reg-args.txt" "$HOME/reg-env.txt"; touch "$HOME/reg-fail"
fakeenv "$(uuid 13)" gamma-foo-press
# a claude.ai login file and an API that refuses the connection: the title step (rc --titles, lib/spawn.sh THE CLAUDE.AI TITLE) fails, and that is one warning line
mkdir -p "$HOME/.claude"; printf '{"claudeAiOauth":{"accessToken":"example-token-not-real"}}\n' > "$HOME/.claude/.credentials.json"
SALA_ANTHROPIC_API="http://127.0.0.1:1" SALA_SPAWN_REGISTER="\"$HOME/fake-register\" \"\$@\"" run gamma-foo-press --project projects/foo --role front --prompt "hello: there" --cwd "$HOME"
rm -f "$HOME/reg-fail" "$HOME/.claude/.credentials.json"
[ "$RC" = 0 ] && [ "$(grep -c 'the claude.ai title was not set' <<< "$OUT")" = 1 ] && has "$OUT" "sala rc --titles --apply --only gamma-foo-press retries it" && ! has "$OUT" "example-token-not-real" && ok "a title step that fails (claude.ai unreachable): one warning line, no token, the spawn still done" || bad "title warning: rc=$RC — $OUT"
[ "$RC" = 0 ] && has "$OUT" "✅ spawned 'gamma-foo-press'" && tmux has-session -t =gamma-foo-press 2>/dev/null && grep -q "^gamma-foo-press	$(uuid 13)	" "$SALA_SIDECAR" && ok "spawned and mapped: exit 0 although the hook failed" || bad "press spawn: rc=$RC — $OUT"
waitfor "grep -qxF \"$(uuid 13) $SALA_MSG_MARK hello: there\" '$TYPED'" 120 && ok "the text mandate typed as the first message, with the marker, one line" || bad "press typed: $(typed_ctx "$TYPED" "$(uuid 13)")"
has "$OUT" "⚠ register: the hook exited 7 (SALA_SPAWN_REGISTER; its output: $SPAWNLOG) — the session is up; register it by hand" && has "$OUT" "mandate : typed as the first message" && ok "the failing hook: one ⚠ line naming the exit code and the log; the session is up" || bad "hook fail: $OUT"
[ "$(paste -sd'|' "$HOME/reg-args.txt")" = "gamma-foo-press|projects/foo|front|" ] && has "$(<"$HOME/reg-env.txt")" "SALA_SPAWN_MANDATE_LINE=hello: there" && has "$(<"$HOME/reg-env.txt")" "SALA_SPAWN_MANDATE_FILE=" && ok "a text mandate: the hook's file argument empty, the line in SALA_SPAWN_MANDATE_LINE" || bad "reg: $(cat "$HOME/reg-args.txt" "$HOME/reg-env.txt")"

echo "== the start directory: a back agent with no --cwd starts in the background brief's directory; --cwd wins; a front agent, a plain spawn and a side session keep \$HOME; a missing directory is refused"
BACKD=$(cd "$BACKD" && pwd -P); OTHERD="$HOME/other-dir"; mkdir -p "$OTHERD"; OTHERD=$(cd "$OTHERD" && pwd -P)
list projects/foo gamma-foo-cwd "cwd test"
run gamma-foo-cwd --project projects/foo --role back --mandate "work" --dry-run
[ "$RC" = 0 ] && has "$OUT" "cwd $BACKD, model" && ok "back, no --cwd: the dry run shows the background brief's directory ($BACKD)" || bad "back dry: rc=$RC — $OUT"
run gamma-foo-cwd --project projects/foo --role back --mandate "work" --cwd "$OTHERD" --dry-run
[ "$RC" = 0 ] && has "$OUT" "cwd $OTHERD, model" && ok "back with --cwd: the dry run shows the directory given" || bad "back --cwd dry: rc=$RC — $OUT"
run gamma-foo-cwd --project projects/foo --role back --mandate "work" --cwd "$HOME" --dry-run
[ "$RC" = 0 ] && has "$OUT" "cwd $(cd "$HOME" && pwd -P), model" && ok "back with --cwd \$HOME: an explicit --cwd wins even when it is \$HOME" || bad "back --cwd home dry: rc=$RC — $OUT"
list projects/foo gamma-foo-fr "front cwd"
run gamma-foo-fr --project projects/foo --role front --dry-run
[ "$RC" = 0 ] && has "$OUT" "cwd $(cd "$HOME" && pwd -P), model" && ok "front, no --cwd: \$HOME as before" || bad "front dry: rc=$RC — $OUT"
run orphan-cwd --dry-run
[ "$RC" = 0 ] && has "$OUT" "cwd $(cd "$HOME" && pwd -P), model" && ok "a plain spawn, no --cwd: \$HOME as before" || bad "plain dry: rc=$RC — $OUT"
SALA_BACK_CWD="$HOME/no-such-brief-dir" run gamma-foo-cwd --project projects/foo --role back --mandate "work" --dry-run
[ "$RC" != 0 ] && has "$OUT" "does not exist here: $HOME/no-such-brief-dir" && has "$OUT" "SALA_BACK_CWD" && ! has "$OUT" "cwd $(cd "$HOME" && pwd -P), model" && ok "SALA_BACK_CWD set but missing: the spawn is refused and the message names the directory (no quiet start in \$HOME)" || bad "missing dir: rc=$RC — $OUT"
[ -z "$($T list-sessions 2>/dev/null | grep gamma-foo-cwd)" ] && ok "the refused spawn made no session" || bad "a session exists after the refusal"
SALA_BACK_CWD="$HOME/no-such-brief-dir" run gamma-foo-cwd --project projects/foo --role back --mandate "work" --cwd "$OTHERD" --dry-run
[ "$RC" = 0 ] && has "$OUT" "cwd $OTHERD, model" && ! has "$OUT" "does not exist here" && ok "the directory missing but --cwd given: --cwd wins, no refusal" || bad "missing dir + cwd: rc=$RC — $OUT"
SALA_BACK_CWD="$HOME/no-such-brief-dir" run gamma-foo-fr --project projects/foo --role front --dry-run
[ "$RC" = 0 ] && ! has "$OUT" "does not exist here" && ok "the directory missing, a front agent: not looked at" || bad "missing dir front: rc=$RC — $OUT"
mkdir -p "$HOME/config-repo/roles/background"
OUT=$(env -u SALA_BACK_CWD "$SALA" spawn gamma-foo-cwd --project projects/foo --role back --mandate "work" --dry-run 2>&1); RC=$?
[ "$RC" = 0 ] && has "$OUT" "cwd $(cd "$HOME" && pwd -P), model" && ! has "$OUT" "does not exist here" && ok "SALA_BACK_CWD unset: \$HOME, even where a conventional config-repo directory exists" || bad "default dir: rc=$RC — $OUT"
rm -rf "$HOME/config-repo"
mkdir -p "$HOME/back-tilde"; OUT=$(SALA_BACK_CWD='~/back-tilde' "$SALA" spawn gamma-foo-cwd --project projects/foo --role back --mandate "work" --dry-run 2>&1); RC=$?
[ "$RC" = 0 ] && has "$OUT" "cwd $(cd "$HOME/back-tilde" && pwd -P), model" && ok "SALA_BACK_CWD with a leading ~ is the home directory's" || bad "tilde dir: rc=$RC — $OUT"
rmdir "$HOME/back-tilde"
fakeenv "$(uuid 15)" gamma-foo-cwd
run gamma-foo-cwd --project projects/foo --role back --mandate "work" --lane subscription-1
[ "$RC" = 0 ] && has "$OUT" "(cwd $BACKD)" && [ "$(tmux display -p -t gamma-foo-cwd:0 '#{pane_current_path}' 2>/dev/null)" = "$BACKD" ] && ok "a real back spawn: the pane's shell started in the brief's directory" || bad "real back: rc=$RC — $OUT / $(tmux display -p -t gamma-foo-cwd:0 '#{pane_current_path}' 2>&1)"
[ "$(awk -F'\t' -v n=gamma-foo-cwd '$1==n {print $4}' "$SALA_SIDECAR")" = "$BACKD" ] && ok "the pane map's cwd column records it (sala restore recreates the session there)" || bad "pane map: $(grep gamma-foo-cwd "$SALA_SIDECAR")"

echo "== the surface: a front agent that answers on Slack starts in the Slack brief's directory (SALA_SLACK_CWD); only a front agent; refusals name the key; no fallback"
SLACKD="$HOME/slack-brief"; mkdir -p "$SLACKD"; SLACKD=$(cd "$SLACKD" && pwd -P)
list projects/foo gamma-foo-sl "chat front"
SALA_SLACK_CWD="$SLACKD" run gamma-foo-sl --project projects/foo --role front --surface slack --dry-run
[ "$RC" = 0 ] && has "$OUT" "cwd $SLACKD, model" && has "$OUT" "as a front agent on the slack surface of projects/foo" && ok "front --surface slack, no --cwd: the dry run shows the Slack brief's directory and the surface" || bad "slack dry: rc=$RC — $OUT"
SALA_SLACK_CWD="$SLACKD" run gamma-foo-sl --project projects/foo --role front --surface slack --cwd "$OTHERD" --dry-run
[ "$RC" = 0 ] && has "$OUT" "cwd $OTHERD, model" && ok "--cwd given: it wins over SALA_SLACK_CWD" || bad "slack --cwd: rc=$RC — $OUT"
SALA_SLACK_CWD="$SLACKD" run gamma-foo-sl --project projects/foo --role front --surface sala --dry-run
[ "$RC" = 0 ] && has "$OUT" "cwd $(cd "$HOME" && pwd -P), model" && ! has "$OUT" "slack" && ok "--surface sala: the default, \$HOME as before, no mention of Slack" || bad "sala dry: rc=$RC — $OUT"
SALA_SLACK_CWD="$SLACKD" run gamma-foo-fr --project projects/foo --role front --dry-run
[ "$RC" = 0 ] && has "$OUT" "cwd $(cd "$HOME" && pwd -P), model" && ok "a front agent with no --surface ignores SALA_SLACK_CWD" || bad "no surface: rc=$RC — $OUT"
SALA_SLACK_CWD="$SLACKD" run gamma-foo-sl --project projects/foo --role back --mandate "work" --surface slack --dry-run
[ "$RC" != 0 ] && has "$OUT" "a slack agent is a front agent" && ok "--surface slack with --role back is refused" || bad "slack back: rc=$RC — $OUT"
OUT=$(env -u SALA_SLACK_CWD "$SALA" spawn gamma-foo-sl --project projects/foo --role front --surface slack --dry-run 2>&1); RC=$?
[ "$RC" != 0 ] && has "$OUT" "SALA_SLACK_CWD" && has "$OUT" "not set" && ! has "$OUT" "cwd $(cd "$HOME" && pwd -P), model" && ok "SALA_SLACK_CWD unset: refused, the message names the key (no start in \$HOME)" || bad "slack unset: rc=$RC — $OUT"
SALA_SLACK_CWD="" run gamma-foo-sl --project projects/foo --role front --surface slack --dry-run
[ "$RC" != 0 ] && has "$OUT" "SALA_SLACK_CWD" && ok "SALA_SLACK_CWD empty is unset" || bad "slack empty: rc=$RC — $OUT"
SALA_SLACK_CWD="$HOME/no-such-slack-dir" run gamma-foo-sl --project projects/foo --role front --surface slack --dry-run
[ "$RC" != 0 ] && has "$OUT" "does not exist here: $HOME/no-such-slack-dir" && has "$OUT" "SALA_SLACK_CWD" && ! has "$OUT" "cwd $(cd "$HOME" && pwd -P), model" && ok "SALA_SLACK_CWD naming a missing directory: refused, the message names the key and the directory" || bad "slack missing: rc=$RC — $OUT"
[ -z "$(tmux list-sessions 2>/dev/null | grep gamma-foo-sl)" ] && ok "a refused slack spawn made no session" || bad "a session exists after the refusal"
mkdir -p "$HOME/slack-tilde"; SALA_SLACK_CWD='~/slack-tilde' run gamma-foo-sl --project projects/foo --role front --surface slack --dry-run
[ "$RC" = 0 ] && has "$OUT" "cwd $(cd "$HOME/slack-tilde" && pwd -P), model" && ok "SALA_SLACK_CWD with a leading ~ is the home directory's" || bad "slack tilde: rc=$RC — $OUT"
rmdir "$HOME/slack-tilde"
for v in telegram Slack ""; do
    SALA_SLACK_CWD="$SLACKD" run gamma-foo-sl --project projects/foo --role front --surface "$v" --dry-run
    [ "$RC" != 0 ] && has "$OUT" "--surface takes sala or slack" && ok "--surface '$v' is refused" || bad "surface '$v': rc=$RC — $OUT"
done
SALA_SLACK_CWD="$SLACKD" run gamma-foo-sl --surface slack --dry-run
[ "$RC" != 0 ] && has "$OUT" "--surface goes with --project" && ok "--surface without --project and --role is refused" || bad "surface alone: rc=$RC — $OUT"
SALA_SLACK_CWD="$SLACKD" run gamma-foo-sl --project projects/foo --surface slack --dry-run
[ "$RC" != 0 ] && ok "--surface with --project and no --role is refused" || bad "surface, no role: rc=$RC — $OUT"
SALA_SLACK_CWD="$SLACKD" run gamma-foo-sl --side --fork-of gamma-foo-fr --surface slack --dry-run
[ "$RC" != 0 ] && has "$OUT" "--side takes no --surface" && ok "a side session takes no --surface" || bad "side surface: rc=$RC — $OUT"
unlist gamma-foo-sl
SALA_SLACK_CWD="$SLACKD" run gamma-foo-sl --project projects/foo --role front --surface slack --dry-run
[ "$RC" = 3 ] && grep -qx 'python3 ~/stackshot/stackshot/fleet/client.py post project-agent projects/foo gamma-foo-sl --role <role> --front --surface slack --mandate "<one line>"' <<< "$OUT" && ok "an unlisted slack agent: the register command it prints carries --surface slack" || bad "slack register: rc=$RC — $OUT"
run gamma-foo-sl --project projects/foo --role front --dry-run
[ "$RC" = 3 ] && ! has "$OUT" "--surface" && ok "an unlisted sala agent: the register command carries no --surface" || bad "sala register: rc=$RC — $OUT"
list projects/foo gamma-foo-sl "chat front"
fakeenv "$(uuid 61)" gamma-foo-sl
SALA_SLACK_CWD="$SLACKD" run gamma-foo-sl --project projects/foo --role front --surface slack --lane subscription-1
[ "$RC" = 0 ] && has "$OUT" "(cwd $SLACKD)" && has "$OUT" "slack surface" && [ "$(tmux display -p -t gamma-foo-sl:0 '#{pane_current_path}' 2>/dev/null)" = "$SLACKD" ] && ok "a real slack spawn: the pane's shell started in SALA_SLACK_CWD's directory" || bad "real slack: rc=$RC — $OUT / $(tmux display -p -t gamma-foo-sl:0 '#{pane_current_path}' 2>&1)"
[ "$(awk -F'\t' -v n=gamma-foo-sl '$1==n {print $4}' "$SALA_SIDECAR")" = "$SLACKD" ] && ok "the pane map's cwd column records it (revive and sala restore start it there)" || bad "slack pane map: $(grep gamma-foo-sl "$SALA_SIDECAR")"
sregf() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); r=[x for x in d["sessions"].values() if x["name"]==sys.argv[2] and x["state"]=="live"][0]; print(r["project"], r["role"], r.get(sys.argv[3], "<absent>"))' "$SALA_SESSIONS_FILE" "$1" "$2" 2>&1; }
[ "$(sregf gamma-foo-sl surface)" = "projects/foo front slack" ] && ok "the registry row carries surface: slack beside project and role" || bad "slack row: $(sregf gamma-foo-sl surface)"
[ "$(sregf gamma-foo-main surface)" = "projects/foo front <absent>" ] && [ "$(sregf gamma-foo-worker surface)" = "projects/foo back <absent>" ] && ok "a sala agent's row has no surface key" || bad "sala rows: $(sregf gamma-foo-main surface) / $(sregf gamma-foo-worker surface)"
OUT=$("$SALA" spawn --list 2>&1); RC=$?
[ "$RC" = 0 ] && grep -E '^gamma-foo-sl +' <<< "$OUT" | grep -q '\[slack\]$' && ! grep -E '^gamma-foo-main +' <<< "$OUT" | grep -q 'slack' && ok "spawn --list marks the slack agent [slack] at the end of its line and no other" || bad "spawn --list: rc=$RC — $OUT"
OUT=$("$SALA" sessions 2>&1)
grep -E '^[0-9a-f]{8} +gamma-foo-sl ' <<< "$OUT" | grep -q 'front \[slack\]' && ok "sessions marks it after the role" || bad "sessions: $OUT"
tmux kill-session -t gamma-foo-sl 2>/dev/null

echo "== the surface follows the project record, not the flag alone: a registered Slack agent spawned without --surface starts in the Slack brief's directory (what tag --auto lists it as)"
SURFREC="$HOME/surface-record.json"
# mksurf <json {agent name: [front, surface or ""]}> → a fresh record with one project, projects/foo. "" is NO surface field (absent: sala);
# "EMPTY" writes `"surface": ""` and "NULL" writes `"surface": null` (a present, empty value: refused, never read as sala)
mksurf() { python3 - "$1" > "$SURFREC" <<'PY'
import json, sys, datetime
spec = json.loads(sys.argv[1])
ags = {n: dict({"front": a[0], "role": n.rsplit("-", 1)[-1], "mandate_line": "m"}, **({"surface": {"EMPTY": "", "NULL": None}.get(a[1], a[1])} if a[1] else {})) for n, a in spec.items()}
t = datetime.datetime.now(datetime.timezone.utc)
print(json.dumps({"schema": 1, "generated": t.strftime("%Y-%m-%dT%H:%M:%SZ"), "projects": {"prj_example": {"id": "prj_example", "key": "projects/foo", "agents": ags}}, "by_key": {"projects/foo": "prj_example"}}))
PY
}
mksurf '{"gamma-foo-rs": [true, "slack"], "gamma-foo-ra": [true, ""], "gamma-foo-rw": [false, ""], "gamma-foo-rb": [false, "slack"], "gamma-foo-rt": [true, "telegram"], "gamma-foo-re": [true, "EMPTY"], "gamma-foo-rn": [true, "NULL"]}'
HOMED=$(cd "$HOME" && pwd -P)
rsrun() { SALA_PROJECT_RECORD="$SURFREC" SALA_SLACK_CWD="$SLACKD" run "$@"; }
rsrun gamma-foo-rs --project projects/foo --role front --dry-run
[ "$RC" = 0 ] && has "$OUT" "cwd $SLACKD, model" && has "$OUT" "as a front agent on the slack surface of projects/foo" && ok "a slack agent in the record, no --surface: the dry run starts it in the Slack brief's directory" || bad "record slack, no flag: rc=$RC — $OUT"
rsrun gamma-foo-rs --project projects/foo --role front --surface slack --dry-run
[ "$RC" = 0 ] && has "$OUT" "cwd $SLACKD, model" && ok "the record and --surface slack agree: the Slack brief's directory" || bad "record slack, flag slack: rc=$RC — $OUT"
rsrun gamma-foo-rs --project projects/foo --role front --surface sala --dry-run
[ "$RC" != 0 ] && has "$OUT" "--surface sala conflicts" && has "$OUT" "surface slack" && ! has "$OUT" "[dry-run]" && ok "--surface sala against a slack entry is refused, the message names both values" || bad "flag sala vs slack: rc=$RC — $OUT"
rsrun gamma-foo-ra --project projects/foo --role front --surface slack --dry-run
[ "$RC" != 0 ] && has "$OUT" "--surface slack conflicts" && has "$OUT" "surface sala" && ok "--surface slack against an entry with no surface is refused, the message names both values" || bad "flag slack vs sala: rc=$RC — $OUT"
rsrun gamma-foo-ra --project projects/foo --role front --dry-run
[ "$RC" = 0 ] && has "$OUT" "cwd $HOMED, model" && ! has "$OUT" "slack" && ok "an agent whose entry has no surface keeps \$HOME and no mention of Slack, even with SALA_SLACK_CWD set" || bad "record sala: rc=$RC — $OUT"
rsrun gamma-foo-rw --project projects/foo --role back --mandate work --dry-run
[ "$RC" = 0 ] && has "$OUT" "as a back agent of projects/foo" && ! has "$OUT" "slack" && ok "a back agent in the record is unchanged" || bad "record back: rc=$RC — $OUT"
rsrun gamma-foo-rs --project projects/foo --role back --mandate work --dry-run
[ "$RC" != 0 ] && ! has "$OUT" "[dry-run]" && ok "a slack entry spawned --role back is still refused" || bad "slack entry as back: rc=$RC — $OUT"
rsrun gamma-foo-rb --project projects/foo --role back --mandate work --dry-run
[ "$RC" != 0 ] && has "$OUT" "project record" && has "$OUT" "a slack agent is a front agent" && ! has "$OUT" "[dry-run]" && ok "a back entry the record calls slack: the spawn is refused, the message names the project record and says why" || bad "back+slack entry: rc=$RC — $OUT"
rsrun gamma-foo-rt --project projects/foo --role front --dry-run
[ "$RC" != 0 ] && has "$OUT" "project record" && has "$OUT" "surface 'telegram'" && ! has "$OUT" "[dry-run]" && ok "an entry with a surface sala does not know: the spawn is refused, the message names the project record and the value" || bad "record telegram: rc=$RC — $OUT"
rsrun gamma-foo-rt --project projects/foo --role front --surface sala --dry-run
[ "$RC" != 0 ] && has "$OUT" "surface 'telegram'" && ok "... with --surface sala too" || bad "record telegram, flag sala: rc=$RC — $OUT"
rsrun gamma-foo-rt --project projects/foo --role front --cwd "$OTHERD" --dry-run
[ "$RC" != 0 ] && has "$OUT" "surface 'telegram'" && ok "... and with --cwd (the directory is not the question: the row would be refused by tag --auto)" || bad "record telegram, --cwd: rc=$RC — $OUT"
SALA_AGENT_CHECK=off rsrun gamma-foo-rt --project projects/foo --role front --dry-run
[ "$RC" != 0 ] && has "$OUT" "surface 'telegram'" && ok "... and with SALA_AGENT_CHECK=off (the record is read either way)" || bad "record telegram, check off: rc=$RC — $OUT"
rsrun gamma-foo-rt --dry-run
[ "$RC" != 0 ] && has "$OUT" "surface 'telegram'" && ok "a bare spawn of such a name is refused too" || bad "bare telegram: rc=$RC — $OUT"
SALA_SESSIONS=off rsrun gamma-foo-rs --project projects/foo --role front --dry-run
[ "$RC" = 0 ] && has "$OUT" "cwd $SLACKD, model" && ok "SALA_SESSIONS=off (registry writes off) does not stop the read of the record: a slack entry still starts in the Slack brief's directory" || bad "sessions off, record slack: rc=$RC — $OUT"
SALA_SESSIONS=off rsrun gamma-foo-ra --project projects/foo --role front --surface slack --dry-run
[ "$RC" != 0 ] && has "$OUT" "--surface slack conflicts" && ok "SALA_SESSIONS=off: the conflict with the record is refused as well" || bad "sessions off, conflict: rc=$RC — $OUT"
rsrun gamma-foo-re --project projects/foo --role front --dry-run
[ "$RC" != 0 ] && has "$OUT" "project record" && has "$OUT" "empty surface: a surface is sala or slack" && ! has "$OUT" "[dry-run]" && ok "an entry with an explicit empty surface (\"\"): the spawn is refused, the message names the project record and the empty value" || bad "record empty: rc=$RC — $OUT"
rsrun gamma-foo-rn --project projects/foo --role front --dry-run
[ "$RC" != 0 ] && has "$OUT" "empty surface" && ! has "$OUT" "[dry-run]" && ok "... and an explicit null surface is refused the same way" || bad "record null: rc=$RC — $OUT"
rsrun gamma-foo-re --project projects/foo --role front --surface sala --dry-run
[ "$RC" != 0 ] && has "$OUT" "empty surface" && ok "... with --surface sala too (an empty entry is not read as sala)" || bad "record empty, flag sala: rc=$RC — $OUT"
rsrun gamma-foo-re --dry-run
[ "$RC" != 0 ] && has "$OUT" "empty surface" && ok "... and a bare spawn of such a name is refused too" || bad "bare empty: rc=$RC — $OUT"
# a registry that cannot be read must not change the answer: the record alone places the name (it used to fall back to the flag and the default directory)
REGKEEP="$SALA_SESSIONS_FILE.keep"; cp "$SALA_SESSIONS_FILE" "$REGKEEP"; echo '{this is not json' > "$SALA_SESSIONS_FILE"
rsrun gamma-foo-rs --project projects/foo --role front --dry-run
[ "$RC" = 0 ] && has "$OUT" "cwd $SLACKD, model" && ok "a corrupt registry does not change the surface: a slack entry still starts in the Slack brief's directory" || bad "corrupt registry, record slack: rc=$RC — $OUT"
rsrun gamma-foo-re --project projects/foo --role front --dry-run
[ "$RC" != 0 ] && has "$OUT" "empty surface" && ok "a corrupt registry does not change a refusal either" || bad "corrupt registry, record empty: rc=$RC — $OUT"
mv -f "$REGKEEP" "$SALA_SESSIONS_FILE"
list projects/foo gamma-foo-rs "page line"   # a record that cannot answer: pages.py's stub answers the listing, and the surface is the flag's alone (spawn must not depend on stackshot being reachable)
SALA_PROJECT_RECORD=/nonexistent SALA_SLACK_CWD="$SLACKD" run gamma-foo-rs --project projects/foo --role front --dry-run
[ "$RC" = 0 ] && has "$OUT" "cwd $HOMED, model" && ok "a missing record is no refusal: the flag alone decides" || bad "missing record: rc=$RC — $OUT"
cp "$SURFREC" "$SURFREC.keep"; python3 -c 'import json,sys; f=sys.argv[1]; d=json.load(open(f)); d["generated"]="2020-01-01T00:00:00Z"; json.dump(d, open(f,"w"))' "$SURFREC"
rsrun gamma-foo-rs --project projects/foo --role front --surface slack --dry-run
[ "$RC" = 0 ] && has "$OUT" "cwd $SLACKD, model" && ok "a stale record is no refusal: the flag alone decides" || bad "stale record: rc=$RC — $OUT"
mv "$SURFREC.keep" "$SURFREC"; unlist gamma-foo-rs
OUT=$(env -u SALA_SLACK_CWD SALA_PROJECT_RECORD="$SURFREC" "$SALA" spawn gamma-foo-rs --project projects/foo --role front --dry-run 2>&1); RC=$?
[ "$RC" != 0 ] && has "$OUT" "SALA_SLACK_CWD" && has "$OUT" "not set" && ! has "$OUT" "[dry-run]" && ok "a slack entry, SALA_SLACK_CWD unset: refused naming the key, never started in \$HOME" || bad "record slack, unset: rc=$RC — $OUT"
SALA_PROJECT_RECORD="$SURFREC" SALA_SLACK_CWD="$HOME/no-such-slack-dir" run gamma-foo-rs --project projects/foo --role front --dry-run
[ "$RC" != 0 ] && has "$OUT" "does not exist here: $HOME/no-such-slack-dir" && ok "a slack entry, SALA_SLACK_CWD naming a missing directory: refused" || bad "record slack, missing dir: rc=$RC — $OUT"
rsrun gamma-foo-rs --project projects/foo --role front --cwd "$OTHERD" --dry-run
[ "$RC" = 0 ] && has "$OUT" "cwd $OTHERD, model" && ok "--cwd still wins over the record's surface" || bad "record slack, --cwd: rc=$RC — $OUT"
rsrun gamma-foo-rs --dry-run
[ "$RC" = 0 ] && has "$OUT" "cwd $SLACKD, model" && ok "a bare spawn of a name the record lists as slack (tag --auto marks the row slack) starts in the Slack brief's directory too" || bad "bare slack: rc=$RC — $OUT"
rsrun gamma-foo-ra --dry-run
[ "$RC" = 0 ] && has "$OUT" "cwd $HOMED, model" && ok "a bare spawn of a sala entry keeps \$HOME" || bad "bare sala: rc=$RC — $OUT"
# a real spawn: the pane starts in the Slack brief's directory and the row says slack, with no flag at all
fakeenv "$(uuid 16)" gamma-foo-rs
rsrun gamma-foo-rs --project projects/foo --role front --lane subscription-1
[ "$RC" = 0 ] && [ "$(tmux display -p -t gamma-foo-rs:0 '#{pane_current_path}' 2>/dev/null)" = "$SLACKD" ] && [ "$(sregf gamma-foo-rs surface)" = "projects/foo front slack" ] && ok "a real spawn with no --surface: the pane's shell is in the Slack brief's directory and the row says slack" || bad "real record slack: rc=$RC — $OUT / $(tmux display -p -t gamma-foo-rs:0 '#{pane_current_path}' 2>&1) / $(sregf gamma-foo-rs surface)"
tmux kill-session -t gamma-foo-rs 2>/dev/null
rm -f "$SURFREC"

echo "== the surface through the queue: the shape, the plan, the marker's arguments"
for args in "spawn x --project projects/foo --role back --mandate m --surface slack --from t --words x" "spawn x --project projects/foo --role front --surface telegram --from t --words x" \
            "spawn x --project projects/foo --role front --surface --from t --words x" "spawn x --side --fork-of gamma-foo-fr --surface slack --from t --words x"; do
    eval "enq $args"; [ "$RC" = 2 ] && has "$OUT" "✗" && ok "refused (exit 2): op ${args% --from*}" || bad "op $args: rc=$RC — $OUT"
done
[ "$(queued)" = 0 ] && ok "nothing queued by those" || bad "left: $(ls "$OPS" 2>/dev/null)"
list projects/foo gamma-foo-slq "slack queued"
SALA_SLACK_CWD="$SLACKD" enq --plan spawn gamma-foo-slq --project projects/foo --role front --surface slack
[ "$RC" = 0 ] && has "$OUT" "plan: salamander spawn gamma-foo-slq --project projects/foo --role front --surface slack" && has "$OUT" "on the slack surface" && has "$OUT" "plan only: nothing queued" && [ "$(queued)" = 0 ] && ok "--plan: the slack surface in the command and the dry run, nothing queued" || bad "slack plan: rc=$RC — $OUT"
SALA_SLACK_CWD="$SLACKD" enq spawn gamma-foo-slq --project projects/foo --role front --surface slack --from sala-test-h --words "queue the slack one"
[ "$RC" = 0 ] && [ -n "$ID" ] && [ "$(mvals "$ID" arg | paste -sd'|' -)" = "gamma-foo-slq|--project|projects/foo|--role|front|--surface|slack" ] && ok "the marker's arg= lines carry --surface slack" || bad "slack queued: rc=$RC $(mvals "$ID" arg | paste -sd'|' -) — $OUT"
"$SALA" op --cancel "$ID" >/dev/null 2>&1
enq spawn gamma-foo-slq --project projects/foo --role front --surface sala --from sala-test-h --words "queue the sala one"
[ "$RC" = 0 ] && [ -n "$ID" ] && [ "$(mvals "$ID" arg | paste -sd'|' -)" = "gamma-foo-slq|--project|projects/foo|--role|front|--surface|sala" ] && ok "--surface sala is accepted: the marker keeps the arguments as typed" || bad "sala queued: rc=$RC $(mvals "$ID" arg | paste -sd'|' -)"
"$SALA" op --cancel "$ID" >/dev/null 2>&1
unlist gamma-foo-slq

echo "== the launch line's Enter: a pane at a shell that shows ble.sh's multiline banner after the Enter gets one C-j; a pane without it gets none"
STUCKF="$HOME/stuck-cj.txt"; SHELLP="stuck-shell"
tmux new-session -d -s "$SHELLP" -x 100 -y 30 "bash --norc --noprofile -i"
tmux send-keys -t "$SHELLP" "PS1='\$ '; bind -x '\"\\C-j\": echo GOTCJ >> $STUCKF'; clear" Enter; sleep 0.5
shell_send "$SHELLP" "echo ran-one >> $HOME/stuck-ran.txt" 2>"$HOME/stuck-err.txt"
[ ! -e "$STUCKF" ] && grep -q ran-one "$HOME/stuck-ran.txt" && ok "no banner: the line ran on the Enter and no C-j was sent" || bad "clean pane: cj=$(slurp "$STUCKF") ran=$(slurp "$HOME/stuck-ran.txt")"
tmux send-keys -t "$SHELLP" "printf -- '-- MULTILINE --\\n'" Enter; sleep 0.5
shell_send "$SHELLP" "echo ran-two >> $HOME/stuck-ran.txt" 2>"$HOME/stuck-err.txt"
[ "$(grep -c GOTCJ "$STUCKF" 2>/dev/null)" = 1 ] && grep -q ran-two "$HOME/stuck-ran.txt" && ok "the banner on the screen after the Enter: C-j sent once" || bad "stuck pane: cj=$(slurp "$STUCKF") ran=$(slurp "$HOME/stuck-ran.txt")"
has "$(slurp "$HOME/stuck-err.txt")" "still shows the multiline banner" && ok "the banner still there on the second look (this fake never clears it): said on stderr, no second C-j" || bad "stderr: $(slurp "$HOME/stuck-err.txt")"
tmux kill-session -t "$SHELLP" 2>/dev/null
tmux new-session -d -s "$SHELLP" -x 100 -y 30 "sleep 30"
waitfor '[ "$(tmux display-message -p -t "$SHELLP" "#{pane_current_command}")" = sleep ]'   # the pane has exec'd sleep (under load it reports the wrapper shell for a moment)
tmux send-keys -t "$SHELLP" -l -- "-- MULTILINE --"; shell_stuck "$SHELLP" && bad "a banner under a program that is not a shell counted as stuck" || ok "the banner under a program that is not a shell (claude already running): not stuck"
tmux kill-session -t "$SHELLP" 2>/dev/null

echo "== the queue, the shape: a spawn outside the table is refused with nothing queued and no mandate file left"
for args in "spawn --from t --words x" "spawn -x --project projects/foo --role front --from t --words x" "spawn Bad_Name --project projects/foo --role front --from t --words x" \
            "spawn x --project projects/foo --from t --words x" "spawn x --role front --from t --words x" "spawn x --project projects/foo --role back --from t --words x" \
            "spawn x --project projects/foo --role front --bogus --from t --words x" "spawn x --project projects/foo --role front --lane nope --from t --words x" \
            "spawn x --project projects/foo --role back --brief $HOME/nope.md --from t --words x" "spawn x --project projects/foo --role back --mandate '' --from t --words x" \
            "spawn x --project projects/foo --role sideways --mandate 'some text' --from t --words x" "spawn x --project projects/foo --role front --effort huge --from t --words x"; do
    eval "enq $args"; [ "$RC" = 2 ] && has "$OUT" "✗" && ok "refused (exit 2): op ${args% --from*}" || bad "op $args: rc=$RC — $OUT"
done
[ "$(queued)" = 0 ] && [ "$(nmandates)" = 0 ] && ok "nothing queued, no mandate file left (the text written before the shape check is removed)" || bad "left: $(ls "$OPS" "$MANDATES" 2>/dev/null)"
list projects/foo gamma-foo-plan "planned"
enq --plan spawn gamma-foo-plan --project projects/foo --role front --mandate $'line one\nline two'
[ "$RC" = 0 ] && has "$OUT" "plan: salamander spawn gamma-foo-plan --project projects/foo --role front --mandate" && has "$OUT" "[dry-run] would spawn 'gamma-foo-plan'" && has "$OUT" "mandate: the text typed as the first message: line one" && has "$OUT" "plan only: nothing queued" && [ "$(nmandates)" = 0 ] && [ "$(queued)" = 0 ] \
    && ok "--plan: the dry run shown with the mandate's first line, nothing queued, no file written" || bad "--plan: rc=$RC — $OUT"

echo "== the queue, a refusal at queue time: not listed → exit 3 with the register command unindented, nothing queued, no file, the keeper asked with who heard and the owner's words; no page → exit 4"
enq spawn gamma-foo-new --project projects/foo --role back --mandate "new work" --from sala-test-h --words "make gamma-foo-new"
[ "$RC" = 3 ] && has "$OUT" "did not pass (exit 3) — nothing queued" && grep -qx 'REGISTER: projects/foo' <<< "$OUT" && grep -qxF 'python3 ~/stackshot/stackshot/fleet/client.py post project-agent projects/foo gamma-foo-new --role <role> --back --mandate "new work"' <<< "$OUT" && noaddpage "$OUT" && ok "exit 3, the REGISTER: line and the command once more at column 0 (the web layer reads it), no ADD-TO-PAGE" || bad "unlisted at queue: rc=$RC — $OUT"
[ "$(queued)" = 0 ] && [ "$(nmandates)" = 0 ] && ok "nothing queued, the mandate file removed" || bad "left: $(ls "$OPS" "$MANDATES" 2>/dev/null)"
waitask gamma-foo-new && has "$(ask gamma-foo-new)" "was asked for by sala-test-h (\"make gamma-foo-new\")" && [ "$(cmdline "$(ask gamma-foo-new)")" = 'python3 ~/stackshot/stackshot/fleet/client.py post project-agent projects/foo gamma-foo-new --role <role> --back --mandate "new work"' ] && ok "the keeper asked: who heard, the owner's words, the register command" || bad "ask: $(ask gamma-foo-new)"
enq spawn gamma-nope-main --project projects/nope --role front --from t --words w
[ "$RC" = 4 ] && grep -qx 'NO-PAGE: projects/nope' <<< "$OUT" && [ "$(queued)" = 0 ] && ok "no page at queue time: exit 4, NO-PAGE: at column 0, nothing queued" || bad "no page at queue: rc=$RC — $OUT"

echo "== the mandate's transport: a TEXT mandate written to its file at queue time (bytes kept), the marker carrying the path; a FILE passed as it is; cancel removes the file"
list projects/foo gamma-foo-queued "queued work"
TEXT=$'# Queued: work\n\n- "quoted" line\n日本語の行 — そのまま\n- ends with dash -'
enq spawn gamma-foo-queued --project projects/foo --role back --mandate "$TEXT" --from sala-test-h --words "queue it"
[ "$RC" = 0 ] && [ -n "$ID" ] && [ "$(mval "$ID" verb)" = spawn ] && ok "queued op $ID" || { bad "enqueue: rc=$RC — $OUT"; }
MF="$MANDATES/$ID-gamma-foo-queued.md"
[ "$(mvals "$ID" arg | paste -sd'|' -)" = "gamma-foo-queued|--project|projects/foo|--role|back|--mandate|$MF" ] && ok "the marker's arg= lines: the name, the options, --mandate and the FILE's path (never the text)" || bad "args: $(mvals "$ID" arg | paste -sd'|' -)"
[ -f "$MF" ] && printf '%s\n' "$TEXT" | same_file - "$MF" && ok "the file's bytes are the text: newlines, quotes, Japanese, the dashes" || bad "file: $(slurp "$MF")"
"$SALA" op --cancel "$ID" >/dev/null 2>&1; [ ! -f "$MF" ] && [ "$(queued)" = 0 ] && ok "--cancel: the file removed with the marker archived" || bad "after cancel: $(ls "$MANDATES" "$OPS" 2>/dev/null)"
enq spawn gamma-foo-queued --project projects/foo --role back --mandate "$HOME/m2.md" --from t --words "file it"
[ "$RC" = 0 ] && [ "$(mvals "$ID" arg | tail -1)" = "$HOME/m2.md" ] && [ "$(nmandates)" = 0 ] && ok "a readable FILE given: passed as it is, nothing written" || bad "file mandate: $(mvals "$ID" arg | paste -sd'|' -) / $(ls "$MANDATES" 2>/dev/null)"
"$SALA" op --cancel "$ID" >/dev/null 2>&1
enq spawn gamma-foo-queued --project projects/foo --role back --prompt "$HOME/m2.md" --from t --words "text it"
[ "$RC" = 0 ] && [ "$(mvals "$ID" arg | tail -1)" = "$MANDATES/$ID-gamma-foo-queued.md" ] && [ "$(<"$MANDATES/$ID-gamma-foo-queued.md")" = "$HOME/m2.md" ] && ok "--prompt of a path that is a file: text all the same, written to its file" || bad "prompt path: $(mvals "$ID" arg | paste -sd'|' -)"
"$SALA" op --cancel "$ID" >/dev/null 2>&1; [ "$(nmandates)" = 0 ] || bad "mandates left: $(ls "$MANDATES")"

echo "== end to end: queued → the unit → the session up, reading its file → done, the file kept, one post, no claude -p"
: > "$POSTS"; : > "$LAUNCHES"; rm -f "$HOME/helper-runs.txt"
fakeenv "$(uuid 14)" gamma-foo-queued
enq spawn gamma-foo-queued --project projects/foo --role back --mandate "queued text mandate" --from sala-test-h --words "spawn the queued one"
[ "$RC" = 0 ] && [ -n "$ID" ] && has "$OUT" "[dry-run] would spawn 'gamma-foo-queued' as a back agent of projects/foo" && ok "queued op $ID with the plan shown" || { bad "enqueue: rc=$RC — $OUT"; }
MF="$MANDATES/$ID-gamma-foo-queued.md"
tick; grep -q -- "--unit=sala-op-$ID " "$LAUNCHES" && ok "the tick started unit sala-op-$ID" || bad "launches: $(<"$LAUNCHES")"
waitfor "[ -f '$DONE/$ID.op' ]" 120 && [ "$(mval "$ID" state)" = done ] && ok "done, archived" || bad "state: $(mval "$ID" state) — $(tail -8 "$HOME/.claude/salamander-op-$ID.log" 2>/dev/null)"
tmux has-session -t =gamma-foo-queued 2>/dev/null && grep -q "^gamma-foo-queued	$(uuid 14)	" "$SALA_SIDECAR" && ok "the session is up and mapped" || bad "session: $(sessions); map: $(<"$SALA_SIDECAR")"
waitfor "grep -qF \"$(uuid 14) $SALA_MSG_MARK Read $MF in full\" '$TYPED'" 120 && grep "^$(uuid 14) " "$TYPED" | grep -qF "nobody is waiting to confirm" && ok "the session reads the mandate file the queue wrote, and starts on it" || bad "queued typed: $(typed_ctx "$TYPED" "$(uuid 14)")"
[ -f "$MF" ] && [ "$(<"$MF")" = "queued text mandate" ] && ok "the mandate file is still there after the operation (the session reads it at its first prompt)" || bad "file gone: $(ls "$MANDATES" 2>/dev/null)"
[ "$(nposts '✅ *spawned gamma-foo-queued* · asked by sala-test-h · log ')" = 1 ] && [ "$(nposts '')" = 1 ] && [ "$(runs)" = 0 ] && ok "one ✅ post, no claude -p" || bad "posts: $(<"$POSTS"); runs=$(runs)"
grep -q "spawn gamma-foo-queued: spawn-register: no hook configured" "$SPAWNLOG" && ok "the register no-op logged from the unit too" || bad "spawn log: $(<"$SPAWNLOG")"

echo "== a conflict: two queued spawns of one name → the second refused, its file removed; cancelling the first removes its file"
touch "$HOME/norun"; list projects/foo gamma-foo-two "two"
enq spawn gamma-foo-two --project projects/foo --role back --mandate "first" --from t --words "one"; C1="$ID"; [ -n "$C1" ] || bad "first not queued: $OUT"
enq spawn gamma-foo-two --project projects/foo --role back --mandate "second" --from t --words "two"
[ "$RC" != 0 ] && has "$OUT" "names the same session" && [ "$(queued)" = 1 ] && [ "$(ls "$MANDATES"/*-gamma-foo-two.md | wc -l)" = 1 ] && [ -f "$MANDATES/$C1-gamma-foo-two.md" ] && ok "the second: refused (the same session twice), its file removed, the first's kept" || bad "conflict: rc=$RC — $OUT / $(ls "$MANDATES")"
"$SALA" op --cancel "$C1" >/dev/null 2>&1; [ "$(queued)" = 0 ] && [ ! -f "$MANDATES/$C1-gamma-foo-two.md" ] && ok "the first cancelled, its file gone" || bad "after cancel: $(ls "$OPS" "$MANDATES")"
rm -f "$HOME/norun"

echo "== the line removed between the queue and the run: stuck with no claude -p, the keeper asked by the unit with who heard, no session made"
: > "$POSTS"; rm -f "$HOME/helper-runs.txt"; list projects/foo gamma-foo-late "late"
enq spawn gamma-foo-late --project projects/foo --role back --mandate "late work" --from sala-test-h --words "spawn late"
[ "$RC" = 0 ] && [ -n "$ID" ] && ok "queued op $ID (listed at queue time)" || bad "late enqueue: rc=$RC — $OUT"
unlist gamma-foo-late
tick; waitfor "[ -f '$DONE/$ID.op' ]" 120
[ "$(mval "$ID" state)" = stuck ] && has "$(mval "$ID" result)" "exited 3" && has "$(mval "$ID" result)" "no claude -p: only the page's keeper can register the agent" && ok "stuck: exited 3, the result says only the keeper can register the agent" || bad "late: $(cat "$OPS/$ID.op" "$DONE/$ID.op" 2>/dev/null)"
[ "$(runs)" = 0 ] && [ -z "$(mval "$ID" helper)" ] && ! tmux has-session -t =gamma-foo-late 2>/dev/null && ok "no claude -p, no session made" || bad "runs=$(runs) sessions: $(sessions)"
waitask gamma-foo-late && has "$(ask gamma-foo-late)" "was asked for by sala-test-h (\"spawn late\")" && ok "the keeper asked from the unit, with who heard and the owner's words (SALA_OP_FROM, SALA_OP_WORDS exported by the runner)" || bad "late ask: $(ask gamma-foo-late)"
[ "$(nposts '🚨 *spawn of gamma-foo-late is stuck*')" = 1 ] && [ "$(nposts '')" = 1 ] && ok "one 🚨 post" || bad "posts: $(<"$POSTS")"
[ -f "$MANDATES/$ID-gamma-foo-late.md" ] && ok "its mandate file stays (the spawn runs again once the line is there)" || bad "late file gone"

echo "== the queue, a side conversation (tests/side.sh checks the session itself): the shape refused at queue time, the plan, the marker's arguments, a conflict, the retire gate"
for args in "spawn x --side --from t --words x" "spawn gamma-foo-side-wren01 --side --role front --project projects/foo --item board#9001 --from t --words x" \
            "spawn gamma-foo-side-wren01 --side --project projects/foo --from t --words x" "spawn gamma-foo-side-wren01 --side --project projects/foo --item foo --from t --words x" \
            "spawn gamma-foo-side-wren01 --side --fork-of gamma-foo-main --project projects/foo --from t --words x" "spawn gamma-foo-side-wren01 --side --fork-of gamma-foo-main --agents a,b --from t --words x" \
            "spawn gamma-foo-side-wren01 --side --project projects/foo --item board#9001 --agents 'A B' --from t --words x" "spawn gamma-foo-side-wren01 --side --project Projects/foo --item board#9001 --from t --words x" \
            "spawn gamma-foo-side-wren01 --side --from t --words x" "spawn gamma-foo-wren01 --side --project projects/foo --item board#9001 --from t --words x" \
            "spawn gamma-foo-side-wren01 --project projects/foo --role front --item board#9001 --from t --words x" "spawn gamma-foo-side-wren01 --fork-of gamma-foo-main --from t --words x" \
            "spawn gamma-foo-side-wren01 --side --project projects/foo --item board#9001 --bogus --from t --words x"; do
    eval "enq $args"; [ "$RC" = 2 ] && has "$OUT" "✗" && ok "refused (exit 2): op ${args% --from*}" || bad "op $args: rc=$RC — $OUT"
done
NM0=$(nmandates)   # the files earlier sections left (a spawn that is stuck keeps its file)
[ "$(queued)" = 0 ] && [ "$(nmandates)" = "$NM0" ] && ok "nothing queued, no mandate file written" || bad "left: $(ls "$OPS" "$MANDATES" 2>/dev/null)"
enq --plan spawn gamma-foo-side-mica07 --side --project projects/foo --item board#12 --agents gamma-foo-main
[ "$RC" = 0 ] && has "$OUT" "plan: salamander spawn gamma-foo-side-mica07 --side --project projects/foo --item board#12 --agents gamma-foo-main" && has "$OUT" "[dry-run] would spawn 'gamma-foo-side-mica07' as a side session" \
    && has "$OUT" "a side conversation, on no agents map" && has "$OUT" "plan only: nothing queued" && [ "$(queued)" = 0 ] && ok "--plan: the dry run, the side note; nothing queued (the name is on no agents map and needs none)" || bad "side --plan: rc=$RC — $OUT"
enq spawn gamma-foo-side-mica07 --side --project projects/foo --item board#12 --agents gamma-foo-main --mandate "Look at the deploy only." --from sala-test-h --words "talk about 12"
[ "$RC" = 0 ] && [ -n "$ID" ] && [ "$(mval "$ID" verb)" = spawn ] && [ "$(mvals "$ID" arg | paste -sd'|' -)" = "gamma-foo-side-mica07|--side|--project|projects/foo|--item|board#12|--agents|gamma-foo-main|--mandate|$MANDATES/$ID-gamma-foo-side-mica07.md" ] \
    && ok "queued op $ID: the marker's arguments carry --side, the project, the item, the agents and the mandate's FILE" || bad "side enqueue: rc=$RC — $OUT / $(mvals "$ID" arg | paste -sd'|' -)"
SID="$ID"
enq spawn gamma-foo-side-mica07 --side --project projects/foo --item board#13 --from t --words "again"
[ "$RC" != 0 ] && has "$OUT" "names the same session" && [ "$(queued)" = 1 ] && ok "a second spawn of the same name: refused (one session, one op)" || bad "side conflict: rc=$RC — $OUT"
"$SALA" op --cancel "$SID" >/dev/null 2>&1; [ "$(queued)" = 0 ] && [ "$(nmandates)" = "$NM0" ] && ok "cancelled: the marker archived, the mandate file removed" || bad "after cancel: $(ls "$OPS" "$MANDATES")"
enq spawn gamma-foo-side-nopage --side --project projects/nope --item board#12 --from t --words w
[ "$RC" = 4 ] && grep -qx 'NO-PAGE: projects/nope' <<< "$OUT" && [ "$(queued)" = 0 ] && ok "a start about an item of a project with no page: exit 4, NO-PAGE:, nothing queued" || bad "side no page: rc=$RC — $OUT"
fakeenv "$(uuid 51)" gamma-foo-side-wren51
run gamma-foo-side-wren51 --side --project projects/foo --item board#12 --no-confirm --cwd "$HOME"; fake_up gamma-foo-side-wren51
enq retire gamma-foo-side-wren51 --from t --words "close the side one"
[ "$RC" != 0 ] && has "$OUT" "is a side session and its write-up is not done" && [ "$(queued)" = 0 ] && ok "op retire of a side session without its marker: refused at queue time (the plan), nothing queued" || bad "side retire at queue: rc=$RC — $OUT"
printf '%s by test\n' "$(date +%s)" > "$SALA_STATE_DIR/side/gamma-foo-side-wren51.done"
enq --plan retire gamma-foo-side-wren51
[ "$RC" = 0 ] && has "$OUT" "plan only: nothing queued" && ! has "$OUT" "would refuse" && ok "with the marker the plan passes" || bad "side retire plan with marker: rc=$RC — $OUT"
tmux kill-session -t =gamma-foo-side-wren51 2>/dev/null; rm -f "$SALA_STATE_DIR/side/gamma-foo-side-wren51".*

echo "== the project record: stackshot's projects.json answers first, pages.py only when the record cannot"
export SALA_PROJECT_RECORD="$HOME/projects.json"
ncalls() { wc -l < "$HOME/pages-calls.txt" 2>/dev/null || echo 0; }   # pcalls prints "0" twice for an empty log
S0=$(sessions)
# mkrec <age in seconds> <json {page key: {agent name: [front, mandate line[, page_owed]]}}> → the fake published file, written <age> seconds ago
mkrec() { python3 - "$1" "$2" > "$SALA_PROJECT_RECORD" <<'PY'
import json, sys, datetime
age, spec = float(sys.argv[1]), json.loads(sys.argv[2]); projects, by_key = {}, {}
for i, (k, ags) in enumerate(spec.items()):
    pid = "prj_%08x" % (i + 1)
    projects[pid] = {"id": pid, "key": k, "keeper": "gamma-rec", "agents": {n: {"front": a[0], "role": n.rsplit("-", 1)[-1], "mandate_line": a[1], **({"page_owed": True} if len(a) > 2 else {})} for n, a in ags.items()}}
    by_key[k] = pid
t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=age)
print(json.dumps({"schema": 1, "generated": t.strftime("%Y-%m-%dT%H:%M:%SZ"), "projects": projects, "by_key": by_key}))
PY
}
REC='{"projects/foo": {"gamma-rec-main": [true, "Rowan contact (record)"], "gamma-rec-worker": [false, "background work (record)"], "gamma-rec-owed": [true, "registered, line owed", true]}, "projects/bar": {"gamma-bar-main": [true, "bar main"]}}'
mkrec 5 "$REC"; : > "$HOME/pages-calls.txt"; n=$(asks)
run gamma-rec-main --project projects/foo --role front --dry-run
[ "$RC" = 0 ] && has "$OUT" "[dry-run] would spawn 'gamma-rec-main' as a front agent of projects/foo (on its agents map: Rowan contact (record))" && [ "$(ncalls)" = 0 ] && ok "listed in the record (front): the plan passes, pages.py never called" || bad "record front: rc=$RC calls=$(ncalls) — $OUT"
run gamma-rec-worker --project projects/foo --role back --mandate "watch" --dry-run
[ "$RC" = 0 ] && has "$OUT" "as a back agent of projects/foo (on its agents map: background work (record))" && [ "$(ncalls)" = 0 ] && ok "listed in the record with front: false, spawned --role back: passes" || bad "record back: rc=$RC calls=$(ncalls) — $OUT"
run gamma-rec-main --project projects/foo --role back --mandate "watch" --dry-run
[ "$RC" = 1 ] && has "$OUT" "lists 'gamma-rec-main' on projects/foo as a front agent" && has "$OUT" "not a back agent" && has "$OUT" "--role front" && [ "$(ncalls)" = 0 ] && sleep 1 && [ "$(asks)" = "$n" ] && ok "a front entry spawned --role back: refused (exit 1) from the record's front field, nobody asked" || bad "front as back: rc=$RC — $OUT"
run gamma-rec-worker --project projects/foo --role front --dry-run
[ "$RC" = 1 ] && has "$OUT" "lists 'gamma-rec-worker' on projects/foo as a back agent" && [ "$(ncalls)" = 0 ] && ok "a back entry spawned --role front: refused (exit 1)" || bad "back as front: rc=$RC — $OUT"
run gamma-rec-owed --project projects/foo --role front --dry-run
[ "$RC" = 0 ] && has "$OUT" "registered, line owed (the page's line is still owed: registered through client.py post project-agent)" && [ "$(ncalls)" = 0 ] && ok "page_owed: true (registered through post project-agent): listed, the dry run says the page's line is owed" || bad "page_owed: rc=$RC — $OUT"
run gamma-bar-main --project projects/foo --role front --dry-run
[ "$RC" = 3 ] && has "$OUT" "'gamma-bar-main' is not on the agents map of projects/foo" && has "$OUT" "main agent: gamma-rec-main" && has "$OUT" "REGISTER: projects/foo" && noaddpage "$OUT" && [ "$(ncalls)" = 0 ] && ok "another project's agent: not listed on this one - exit 3, REGISTER, the project's -main agent named, pages.py not called" || bad "unlisted: rc=$RC calls=$(ncalls) — $OUT"
has "$OUT" "client.py post project-agent projects/foo gamma-bar-main --role <role> --front" && ok "the refusal names stackshot's register command (post project-agent)" || bad "register hint: $OUT"
# the role is the part of the name after the project's name, cut by the -main agent the record gives (gamma-rec-main gives gamma-rec-)
run gamma-rec-scout --project projects/foo --role back --mandate "scout the queue" --dry-run
[ "$RC" = 3 ] && [ "$(cmdline "$OUT")" = 'python3 ~/stackshot/stackshot/fleet/client.py post project-agent projects/foo gamma-rec-scout --role scout --back --mandate "scout the queue"' ] && [ "$(sed -n '/^REGISTER: /,$p' <<< "$OUT" | grep -v '^   ' | grep -c .)" = 2 ] && noaddpage "$OUT" && ok "an unlisted back agent of a project with a -main agent: the command carries --role scout (the part after gamma-rec-), --back and the mandate; stdout is the two lines only" || bad "role cut: rc=$RC — $OUT"
run gamma-rec-main2 --project projects/foo --role front --dry-run
[ "$RC" = 3 ] && [ "$(cmdline "$OUT")" = 'python3 ~/stackshot/stackshot/fleet/client.py post project-agent projects/foo gamma-rec-main2 --role main2 --front --mandate "<one line>"' ] && ok "a front agent with no mandate: --role cut the same way, the mandate placeholder" || bad "role cut front: rc=$RC — $OUT"
waitask gamma-bar-main && A=$(ask gamma-bar-main) && has "$A" "client.py post project-agent projects/foo gamma-bar-main --role <role> --front --mandate" && noaddpage "$A" && ok "the keeper's message carries the register command (words only) and no page edit" || bad "ask text: $A"
list projects/foo gamma-rec-pages "listed on the page only"
: > "$HOME/pages-calls.txt"; run gamma-rec-pages --project projects/foo --role front --dry-run
[ "$RC" = 3 ] && [ "$(ncalls)" = 0 ] && ok "the project is in the record: the record wins over a pages.py that lists the name (no fallback for an unlisted name)" || bad "record wins: rc=$RC calls=$(<"$HOME/pages-calls.txt") — $OUT"
mkrec 5 '{"projects/foo": {"gamma-rec-solo": [true, "a"], "gamma-rec-b-main": [true, "b"], "gamma-rec-a-main": [true, "a main"], "gamma-rec-0-main": [false, "a back entry ending in -main"]}}'
run gamma-rec-new --project projects/foo --role front --dry-run
[ "$RC" = 3 ] && has "$OUT" "main agent: gamma-rec-a-main" && ok "the project's main is a front entry ending in -main (the first of two by name; a back entry ending so does not count)" || bad "main: rc=$RC — $OUT"

echo "== the record cannot answer: pages.py is the fallback, with its own answers and its own 'cannot tell'"
: > "$HOME/pages-calls.txt"; mkrec 5 '{"projects/bar": {"gamma-bar-main": [true, "bar main"]}}'; list projects/foo gamma-rec-fb "listed on the page"
run gamma-rec-fb --project projects/foo --role front --dry-run
[ "$RC" = 0 ] && has "$OUT" "(on its agents map: listed on the page)" && [ "$(ncalls)" = 2 ] && ok "no such project in the record: pages.py answers (resolve, agent-listed)" || bad "no project: rc=$RC calls=$(ncalls) — $OUT"
run gamma-rec-nope --project projects/nope --role front --dry-run
[ "$RC" = 4 ] && grep -qx 'NO-PAGE: projects/nope' <<< "$OUT" && ok "no such project in the record and no such page: the fallback's exit 4, NO-PAGE" || bad "no page: rc=$RC — $OUT"
run gamma-rec-gone --project projects/foo --role front --dry-run
[ "$RC" = 3 ] && has "$OUT" "'gamma-rec-gone' is not on the agents map of projects/foo" && ok "no such project in the record, name not on the page: the fallback's exit 3" || bad "fallback unlisted: rc=$RC — $OUT"
for how in missing stale garbage schema2 nogenerated; do
    : > "$HOME/pages-calls.txt"
    case "$how" in
        missing) rm -f "$SALA_PROJECT_RECORD" ;;
        stale) mkrec 3600 "$REC" ;;
        garbage) echo '{"schema": 1, "proj' > "$SALA_PROJECT_RECORD" ;;
        schema2) mkrec 5 "$REC"; sed -i 's/"schema": 1/"schema": 2/' "$SALA_PROJECT_RECORD" ;;
        nogenerated) mkrec 5 "$REC"; sed -i 's/"generated": "[^"]*", //' "$SALA_PROJECT_RECORD" ;;
    esac
    run gamma-rec-main --project projects/foo --role front --dry-run
    [ "$RC" = 3 ] && [ "$(ncalls)" = 2 ] && ok "record $how: not used, pages.py asked (resolve, agent-listed) and answers (gamma-rec-main is not on its page)" || bad "record $how: rc=$RC calls=$(ncalls) — $OUT"
done
mkrec 3600 "$REC"; list projects/foo gamma-rec-stale "page says listed"
run gamma-rec-stale --project projects/foo --role front --dry-run
[ "$RC" = 0 ] && has "$OUT" "(on its agents map: page says listed)" && ok "a stale record: the page's answer is used" || bad "stale fallback: rc=$RC — $OUT"
mkrec 5 "$REC"; touch "$HOME/pages-cannot-tell"
run gamma-rec-main --project projects/foo --role front --dry-run
[ "$RC" = 0 ] && ok "pages.py cannot tell but the record can: the record answers" || bad "record beats a blind pages.py: rc=$RC — $OUT"
rm -f "$HOME/pages-cannot-tell"

echo "== neither source can answer: refused (exit 1), never fail-open"
rm -f "$SALA_PROJECT_RECORD"; touch "$HOME/pages-cannot-tell"
run gamma-rec-main --project projects/foo --role front --dry-run
[ "$RC" = 1 ] && has "$OUT" "cannot tell whether the page projects/foo exists" && has "$OUT" "no project record at" && ok "no record and pages.py cannot resolve: refused, both reasons in the message" || bad "cannot tell 1: rc=$RC — $OUT"
rm -f "$HOME/pages-cannot-tell"; touch "$HOME/pages-listed-cannot-tell"; mkrec 3600 "$REC"
run gamma-rec-main --project projects/foo --role front --dry-run
[ "$RC" = 1 ] && has "$OUT" "cannot tell whether 'gamma-rec-main' is on the agents map of projects/foo" && has "$OUT" "stale" && ok "a stale record and pages.py cannot tell who is listed: refused" || bad "cannot tell 2: rc=$RC — $OUT"
rm -f "$HOME/pages-listed-cannot-tell"; mkrec 5 '{"projects/bar": {}}'
SALA_AGENT_CHECK_SCRIPT="$HOME/nowhere.py" run gamma-rec-main --project projects/foo --role front --dry-run
[ "$RC" = 1 ] && has "$OUT" "no pages.py on this box" && ok "no such project in the record and no pages.py: refused" || bad "cannot tell 3: rc=$RC — $OUT"
[ "$(sessions)" = "$S0" ] && ok "none of these made a session" || bad "sessions: $(sessions) (was $S0)"

echo "== agent_unlisted (a plain spawn, rename): a name the record lists is not unlisted, pages.py is not asked; anything else is pages.py's as before"
mkrec 5 "$REC"; : > "$HOME/pages-calls.txt"
agent_unlisted gamma-rec-worker >/dev/null; rc=$?; [ "$rc" = 1 ] && [ "$(ncalls)" = 0 ] && ok "listed on a project of the record (a back agent): not unlisted, no pages.py call" || bad "unlisted listed: rc=$rc calls=$(ncalls)"
run gamma-rec-worker --dry-run; [ "$RC" = 0 ] && has "$OUT" "[dry-run] would spawn 'gamma-rec-worker'" && ok "a plain spawn of a record-listed name passes" || bad "plain listed: rc=$RC — $OUT"
agent_unlisted gamma-rec-owed >/dev/null; rc=$?; [ "$rc" = 1 ] && ok "a name registered through post project-agent (page line owed): not unlisted" || bad "owed: rc=$rc"
agent_unlisted gamma-foo-zzz >/dev/null; rc=$?; [ "$rc" = 0 ] && [ "$(ncalls)" = 1 ] && ok "not in the record: pages.py is asked and its exit 3 refuses, as before" || bad "unlisted: rc=$rc calls=$(ncalls)"
# a plain spawn of an unlisted name finds the page in pages.py's refusal, in the current wording and in the one before Fri Oct 16th 2026
run gamma-rec-zzz --dry-run; [ "$RC" = 3 ] && has "$OUT" "REGISTER: projects/foo" && has "$OUT" "post project-agent projects/foo gamma-rec-zzz --role zzz --front|--back --mandate" && noaddpage "$OUT" && ok "a plain spawn of an unlisted name: the record decides (THE SPAWN GATE), the register command names the project and the role" || bad "plain unlisted: rc=$RC — $OUT"
# with no record (and no client: a box without stackshot's files) pages.py answers, as before (PR B removes this path): its refusal's wording, the current and the one before Fri Oct 16th 2026
rm -f "$SALA_PROJECT_RECORD"
run gamma-foo-zzz --dry-run; [ "$RC" = 3 ] && has "$OUT" "REGISTER: projects/foo" && has "$OUT" "post project-agent projects/foo gamma-foo-zzz --role <role> --front|--back --mandate" && noaddpage "$OUT" && ok "no record: a plain spawn of an unlisted name: the page is read from pages.py's current refusal wording" || bad "plain unlisted no record: rc=$RC — $OUT"
run oldfmt-zzz --dry-run; [ "$RC" = 3 ] && has "$OUT" "REGISTER: projects/foo" && ok "no record: a plain spawn of an unlisted name: the page is read from the old '(steward …' wording too" || bad "plain unlisted, old wording: rc=$RC — $OUT"
rm -f "$SALA_PROJECT_RECORD"; agent_unlisted gamma-rec-worker >/dev/null; rc=$?; [ "$rc" = 0 ] && ok "no record: pages.py's answer is used (it does not list the name)" || bad "no record: rc=$rc"
unset SALA_PROJECT_RECORD

export SALA_PROJECT_RECORD="$HOME/projects.json"
echo "== THE SPAWN GATE: the record decides first, stackshot's register call is the yes, the pane starts only on it (a stub client.py, no network)"
# the stub stackshot client (SALA_STACKSHOT_CLIENT): `post project-agent` adds the agent to the fake record unless the mode says otherwise and logs whether the pane existed AT THE CALL;
# $HOME/client-mode: ok (default) | 409 | 403 | 400 (stackshot's refusal) | down (not reached) | noshow (200, but the record shows nothing)
cat > "$HOME/fake-client.py" <<'PY'
import datetime, json, os, subprocess, sys
home = os.environ["HOME"]; rec = os.environ["SALA_PROJECT_RECORD"]; a = sys.argv[1:]
open(home + "/client-calls.txt", "a").write(" ".join(a) + "\n")
mode = open(home + "/client-mode").read().strip() if os.path.exists(home + "/client-mode") else "ok"
def load(): return json.load(open(rec))
def save(d): d["generated"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"); json.dump(d, open(rec, "w"))
def proj(d, key):
    pid = d["by_key"].get(key); return d["projects"].get(pid) if pid else None
if a[:2] == ["post", "project-agent"]:
    key, name = a[2], a[3]
    o = {a[i]: (a[i + 1] if i + 1 < len(a) else "") for i in range(4, len(a)) if a[i].startswith("--")}
    r = subprocess.run(["tmux", "-S", os.environ["SALA_TMUX_SOCKET"], "has-session", "-t", "=" + name], capture_output=True)
    open(home + "/client-pane-at-call.txt", "a").write("%s %s\n" % (name, "pane-existed" if r.returncode == 0 else "no-pane"))
    if mode == "down": sys.stderr.write("stackshot: not reached [0] connection refused\n"); sys.exit(1)
    if mode in ("409", "403", "400"): sys.stderr.write("stackshot: agent not registered [%s] stub reason %s for %s\n" % (mode, mode, name)); sys.exit(1)
    if mode != "noshow":
        d = load(); p = proj(d, key); p["agents"][name] = {"front": "--front" in a, "role": a[a.index("--role") + 1], "mandate_line": a[a.index("--mandate") + 1]}; save(d)
    print(json.dumps({"project": key, "agent": name, "page_owed": False, "note": "registered"})); sys.exit(0)
if a[:2] == ["get", "project"]:
    if mode == "down": sys.stderr.write("stackshot: not reached [0] connection refused\n"); sys.exit(1)
    p = proj(load(), a[2])
    if p is None: sys.stderr.write("stackshot: no such project [404]\n"); sys.exit(1)
    print(json.dumps(p)); sys.exit(0)
sys.stderr.write("fake client: unexpected %s\n" % " ".join(a)); sys.exit(2)
PY
export SALA_STACKSHOT_CLIENT="$HOME/fake-client.py" SALA_READBACK_WAIT=2 SALA_READBACK_POLL=1
cposts() { local n; n=$(grep -c '^post project-agent ' "$HOME/client-calls.txt" 2>/dev/null); echo "${n:-0}"; }   # (grep -c prints 0 and exits 1: no `|| echo 0`)
creset() { : > "$HOME/client-calls.txt"; : > "$HOME/client-pane-at-call.txt"; rm -f "$HOME/client-mode"; }
mkrec 5 "$REC"; creset; S0=$(sessions)

# listed -> the pane starts, stackshot is not asked to register
fakeenv "$(uuid 41)" gamma-rec-worker
run gamma-rec-worker --lane subscription-1
[ "$RC" = 0 ] && [ "$(cposts)" = 0 ] && tmux has-session -t =gamma-rec-worker 2>/dev/null && ok "gate: a name the record lists: the pane starts, no register call" || bad "gate listed: rc=$RC calls=$(cposts) — $OUT"
tmux kill-session -t =gamma-rec-worker 2>/dev/null

# unlisted, no --role/--mandate: refused (3) with the reason and the register command, no pane, no call
creset; run gamma-rec-nobody
[ "$RC" = 3 ] && has "$OUT" "is not on stackshot's project record" && has "$OUT" "REGISTER: projects/foo" && [ -n "$(cmdline "$OUT")" ] && [ "$(cposts)" = 0 ] && [ "$(sessions)" = "$S0" ] && ok "gate: unlisted with no flags: refused (exit 3) with the reason and the register command, no call, no pane" || bad "gate unlisted: rc=$RC calls=$(cposts) sessions=$(sessions) — $OUT"
run gamma-rec-nobody --role nobody
[ "$RC" = 3 ] && [ "$(cposts)" = 0 ] && [ "$(sessions)" = "$S0" ] && ok "gate: --role with no --mandate is no registration either: refused, no pane" || bad "gate role only: rc=$RC — $OUT"
run gamma-zzz-nobody --dry-run
[ "$RC" = 3 ] && has "$OUT" "no project of the record owns the name" && ok "gate: a name no project of the record owns: refused, the reason says so" || bad "gate no owner: rc=$RC — $OUT"

# unlisted with --role and --mandate: registered with sala-spawn BEFORE the pane exists, the pane starts after the 200, the record is read back
creset; fakeenv "$(uuid 42)" gamma-rec-zed
run gamma-rec-zed --role zed --mandate "zed's work" --lane subscription-1
[ "$RC" = 0 ] && tmux has-session -t =gamma-rec-zed 2>/dev/null && grep -qx "post project-agent projects/foo gamma-rec-zed --role zed --back --mandate zed's work --sender sala-spawn" "$HOME/client-calls.txt" && ok "gate: unlisted with --role/--mandate: post project-agent with the label sala-spawn, a back agent by default, then the pane" || bad "gate register: rc=$RC — $OUT $(cat "$HOME/client-calls.txt")"
grep -qx "gamma-rec-zed no-pane" "$HOME/client-pane-at-call.txt" && ok "gate: the pane did not exist when stackshot was asked (the pane starts only on the 200)" || bad "gate order: $(cat "$HOME/client-pane-at-call.txt")"
has "$OUT" "read back from the record" && ok "gate: the registration is read back" || bad "gate read-back line: $OUT"
tmux kill-session -t =gamma-rec-zed 2>/dev/null
creset; fakeenv "$(uuid 43)" gamma-rec-fronty
run gamma-rec-fronty --role fronty --front --mandate "front work" --lane subscription-1
[ "$RC" = 0 ] && grep -q "post project-agent projects/foo gamma-rec-fronty --role fronty --front --mandate front work --sender sala-spawn" "$HOME/client-calls.txt" && ok "gate: --front lists a front agent" || bad "gate front: rc=$RC — $OUT"
tmux kill-session -t =gamma-rec-fronty 2>/dev/null
# a project spawn of a name the record lacks, with a mandate: registered the same way (the role is the part after the project's name)
creset; fakeenv "$(uuid 44)" gamma-rec-newb
run gamma-rec-newb --project projects/foo --role back --mandate "newb work" --lane subscription-1
[ "$RC" = 0 ] && grep -q "post project-agent projects/foo gamma-rec-newb --role newb --back --mandate newb work --sender sala-spawn" "$HOME/client-calls.txt" && ok "gate: a project spawn of a name the record lacks (with its mandate): registered, then the pane" || bad "gate project register: rc=$RC — $OUT $(cat "$HOME/client-calls.txt")"
tmux kill-session -t =gamma-rec-newb 2>/dev/null
# a front project agent with no mandate has nothing to list it with: refused as before
creset; run gamma-rec-nofront --project projects/foo --role front
[ "$RC" = 3 ] && [ "$(cposts)" = 0 ] && ok "gate: a front project agent with no mandate: refused as before (exit 3), no call" || bad "gate no mandate: rc=$RC — $OUT"
# --dry-run asks nothing and makes nothing
creset; run gamma-rec-dry --role dry --mandate "dry" --dry-run
[ "$RC" = 0 ] && has "$OUT" "stackshot is asked to list it on projects/foo as a back agent" && [ "$(cposts)" = 0 ] && [ "$(sessions)" = "$S0" ] && ok "gate: --dry-run says it would register and asks nothing" || bad "gate dry: rc=$RC calls=$(cposts) — $OUT"

# stackshot's refusal (409, 403, 400): no pane, its reason printed, exit 6
for st in 409 403 400; do
    creset; echo "$st" > "$HOME/client-mode"; run gamma-rec-no$st --role r$st --mandate "no"
    [ "$RC" = 6 ] && has "$OUT" "[$st] stub reason $st" && has "$OUT" "so no session was made" && [ "$(sessions)" = "$S0" ] && ok "gate: stackshot answers $st: stackshot's reason is printed, exit 6, no pane" || bad "gate $st: rc=$RC sessions=$(sessions) — $OUT"
done
# stackshot unreachable: refused, no pane
creset; echo down > "$HOME/client-mode"; run gamma-rec-nodown --role nodown --mandate "no"
[ "$RC" = 6 ] && has "$OUT" "[0]" && [ "$(sessions)" = "$S0" ] && ok "gate: stackshot not reached: refused (exit 6), no pane" || bad "gate down: rc=$RC — $OUT"
# 200 but the record does not show it: no pane
creset; echo noshow > "$HOME/client-mode"; run gamma-rec-noshow --role noshow --mandate "no"
[ "$RC" = 6 ] && has "$OUT" "does not show it" && [ "$(sessions)" = "$S0" ] && ok "gate: the read-back fails: refused (exit 6), no pane left behind" || bad "gate noshow: rc=$RC sessions=$(sessions) — $OUT"
rm -f "$HOME/client-mode"
# the read-back failing leaves a name the record may or may not show: the refusal says to run the same spawn again
creset; echo noshow > "$HOME/client-mode"; run gamma-rec-noshow2 --role noshow2 --mandate "no"
[ "$RC" = 6 ] && has "$OUT" "run the same spawn again" && ok "gate: the read-back refusal says how to go on (run the same spawn again)" || bad "gate noshow retry text: rc=$RC — $OUT"
rm -f "$HOME/client-mode"
# AFTER the 200 and the read-back the pane cannot be made (a local launch failure): the name is registered and no session exists. The message says so and how to retry,
# and the same spawn again succeeds without registering twice (the record lists the name now, so the pane simply starts)
eval "tmux() { if [ -e \"$HOME/tmux-fail-new\" ] && [ \"\${1:-}\" = new-session ]; then return 1; fi; command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux
creset; fakeenv "$(uuid 45)" gamma-rec-rcv; : > "$HOME/tmux-fail-new"
run gamma-rec-rcv --role rcv --mandate "rcv work" --lane subscription-1
rm -f "$HOME/tmux-fail-new"
[ "$RC" != 0 ] && [ "$(cposts)" = 1 ] && ! tmux has-session -t =gamma-rec-rcv 2>/dev/null && has "$OUT" "'gamma-rec-rcv' is registered with stackshot on projects/foo" && has "$OUT" "run the same spawn again" && has "$OUT" "same --role, --front/--back and --mandate" \
    && ok "gate: registered, then the pane cannot be made: no session, the message says the name is registered and how to retry (rc $RC)" || bad "gate launch failure: rc=$RC calls=$(cposts) — $OUT"
fakeenv "$(uuid 45)" gamma-rec-rcv
run gamma-rec-rcv --role rcv --mandate "rcv work" --lane subscription-1
[ "$RC" = 0 ] && [ "$(cposts)" = 1 ] && tmux has-session -t =gamma-rec-rcv 2>/dev/null && ! has "$OUT" "is registered with stackshot on projects/foo but" && ok "gate: the same spawn again is idempotent: the pane starts, no second registration" || bad "gate repeat: rc=$RC calls=$(cposts) — $OUT"
tmux kill-session -t =gamma-rec-rcv 2>/dev/null
# a retry that names the other side is refused by the record (the registration's side is the record's), nothing registered twice
creset; : > "$HOME/tmux-fail-new"; run gamma-rec-rcv2 --project projects/foo --role back --mandate "rcv2 work" --lane subscription-1; rm -f "$HOME/tmux-fail-new"
run gamma-rec-rcv2 --project projects/foo --role front --mandate "rcv2 work" --lane subscription-1
[ "$RC" != 0 ] && [ "$(cposts)" = 1 ] && has "$OUT" "as a back agent" && ! tmux has-session -t =gamma-rec-rcv2 2>/dev/null && ok "gate: a retry that names the other side is refused by the record, nothing registered twice" || bad "gate repeat other side: rc=$RC calls=$(cposts) — $OUT"

# THE EXEMPTION'S REACH on a project spawn: it skips the requirement to be listed, never the role of a name the record DOES list
mkrec 5 '{"projects/foo": {"gamma-rec-main": [true, "main"], "gamma-rec-test-role": [false, "back one"], "gamma-rec-probe-front": [true, "front one"]}}'; creset
run gamma-rec-test-role --project projects/foo --role front --mandate "x" --dry-run
[ "$RC" = 1 ] && has "$OUT" "lists 'gamma-rec-test-role' on projects/foo as a back agent" && has "$OUT" "not a front agent" && [ "$(cposts)" = 0 ] && ok "exempt name, listed with the other role: a --project spawn is refused (exit 1), as for any name" || bad "exempt role mismatch: rc=$RC — $OUT"
run gamma-rec-probe-front --project projects/foo --role back --mandate "x" --dry-run
[ "$RC" = 1 ] && has "$OUT" "lists 'gamma-rec-probe-front' on projects/foo as a front agent" && ok "exempt name (*-probe-*), listed as front, spawned back: refused" || bad "exempt role mismatch 2: rc=$RC — $OUT"
run gamma-rec-test-role --project projects/foo --role back --mandate "x" --dry-run
[ "$RC" = 0 ] && has "$OUT" "on its agents map: back one" && ok "exempt name, listed with the same role: passes, the record's line is shown" || bad "exempt role match: rc=$RC — $OUT"
echo down > "$HOME/client-mode"
run gamma-rec-test-fresh --project projects/foo --role back --mandate "x" --dry-run
[ "$RC" = 0 ] && has "$OUT" "not checked (a throwaway's name" && [ "$(cposts)" = 0 ] && ok "exempt name the record does not list: still no registration, no stackshot call" || bad "exempt unlisted project spawn: rc=$RC — $OUT"
rm -f "$HOME/client-mode"; mkrec 5 "$REC"
# the queue: an exit 6 is stuck with no claude -p (no pane was made)
: > "$POSTS"; rm -f "$HOME/helper-runs.txt"; echo 409 > "$HOME/client-mode"
enq spawn gamma-rec-opq --project projects/foo --role back --mandate "queue work" --from sala-test-h --words "spawn opq"
tick; waitfor "[ -f '$DONE/$ID.op' ]" 120
[ "$(mval "$ID" state)" = stuck ] && has "$(mval "$ID" result)" "exited 6" && has "$(mval "$ID" result)" "stackshot would not register the agent" && [ "$(runs)" = 0 ] && ! tmux has-session -t =gamma-rec-opq 2>/dev/null && ok "gate through the queue: exit 6 is stuck with no claude -p and no pane" || bad "gate op: $(cat "$OPS/$ID.op" "$DONE/$ID.op" 2>/dev/null)"
rm -f "$HOME/client-mode"

# THE EXCEPTIONS (a closed list, one function): each class skips the check, so a stackshot that is down asks nothing and refuses nothing
echo down > "$HOME/client-mode"; creset; echo down > "$HOME/client-mode"
for ex in scratch-abc gamma-rec-check-1 gamma-rec-test-1 gamma-rec-probe-1; do
    run "$ex" --dry-run
    [ "$RC" = 0 ] && has "$OUT" "[dry-run] would spawn '$ex'" && ok "gate exception: $ex (a throwaway's name): no check" || bad "gate exception $ex: rc=$RC — $OUT"
done
run --dry-run; [ "$RC" = 0 ] && has "$OUT" "[dry-run] would spawn 'scratch-" && ok "gate exception: no name at all (an auto-generated throwaway): no check" || bad "gate exception generated: rc=$RC — $OUT"
run gamma-rec-side-wren70 --side --project projects/foo --item board#9001 --dry-run
[ "$RC" = 0 ] && ok "gate exception: a side session (spawn --side): no check" || bad "gate exception side: rc=$RC — $OUT"
[ "$(cposts)" = 0 ] && ok "gate exceptions: stackshot was not asked at all" || bad "gate exceptions asked: $(cat "$HOME/client-calls.txt")"
SALA_SHELL_SESSION=sala-shell agent_gate_exempt sala-shell 0 0 >/dev/null && ok "gate exception: sala's own shell session (SALA_SHELL_SESSION)" || bad "gate exception shell"
agent_gate_exempt gamma-rec-zzz 0 0 >/dev/null && bad "gate exception: an ordinary agent name is not exempt" || ok "gate: an ordinary agent name is not on the exceptions list"
agent_gate_exempt gamma-rec-zzz 1 0 >/dev/null && ok "gate exception: the side flag" || bad "gate exception side flag"
agent_gate_exempt gamma-rec-zzz 0 1 >/dev/null && ok "gate exception: the generated flag" || bad "gate exception generated flag"
rm -f "$HOME/client-mode"

echo "== agent_name_check (spawn --suggest-name): stackshot's name check when it answers, sala's own suggestion when it does not (a stub command)"
cat > "$HOME/fake-namecheck" <<'EOF'
#!/bin/bash
# <key> <name> [<name> ...] (stackshot's `client.py get agent-name` form) → stackshot's answer: the FIRST name invalid (taken), the others valid; $HOME/namecheck-mode:
#   allbad | 404 | garbage | slow | prefix | listed | pending | hub | retired (every name invalid with that code, `listed` only for the first)
key=$1; shift; echo "$key $(IFS=,; echo "$*")" >> "$HOME/namecheck-calls.txt"
mode=$(cat "$HOME/namecheck-mode" 2>/dev/null)
case "$mode" in
    404) echo "stackshot: no such route [404]" >&2; exit 1 ;;
    garbage) echo "<html>not json</html>"; exit 0 ;;
    slow) sleep 30; exit 0 ;;
esac
python3 -c '
import json, sys
mode, key, ns = sys.argv[1], sys.argv[2], sys.argv[3:]
texts = {"prefix": "an agent of %s is called gamma-rec-<role>" % key, "listed": "already listed on %s" % key, "pending": "pending for another sender on %s" % key,
         "hub": "%s is a hub: its agents are not changed" % key, "retired": "%s is retired" % key, "allbad": "taken in stub"}
if mode in texts:
    res = [{"name": n, "valid": False, "code": ("listed" if mode == "listed" and i == 0 else "prefix" if mode == "listed" else "taken" if mode == "allbad" else mode), "reason": texts[mode]} for i, n in enumerate(ns)]
    print(json.dumps({"results": res, "first_free": None, "prefixes": ["gamma-rec"]}))
else:
    print(json.dumps({"results": [{"name": n, "valid": i > 0, "code": "ok" if i > 0 else "taken", "reason": "" if i > 0 else "taken in stub"} for i, n in enumerate(ns)], "first_free": ns[1] if len(ns) > 1 else None, "prefixes": ["gamma-rec"]}))
' "$mode" "$key" "$@"
EOF
chmod +x "$HOME/fake-namecheck"; : > "$HOME/namecheck-calls.txt"; rm -f "$HOME/namecheck-mode"
export SALA_AGENT_NAME_CMD="$HOME/fake-namecheck"
out=$(agent_name_check projects/foo gamma-rec-a gamma-rec-b gamma-rec-c); rc=$?
[ "$rc" = 0 ] && [ "$out" = gamma-rec-b ] && [ "$(cat "$HOME/namecheck-calls.txt")" = "projects/foo gamma-rec-a,gamma-rec-b,gamma-rec-c" ] && ok "name check: the first name stackshot calls valid is the answer; the key and the names are passed as one comma list" || bad "name check: rc=$rc out=$out calls=$(cat "$HOME/namecheck-calls.txt")"
echo allbad > "$HOME/namecheck-mode"; out=$(agent_name_check projects/foo gamma-rec-a gamma-rec-b); rc=$?
[ "$rc" = 2 ] && has "$out" "gamma-rec-a: taken in stub" && ok "name check: none valid: rc 2 with the reasons" || bad "name check allbad: rc=$rc out=$out"
# stackshot's live codes (stubs, never the real endpoint): the reason and the code reach the caller; a `listed` name is "already ours" (rc 3, no refusal); pending, hub and retired are not valid
echo prefix > "$HOME/namecheck-mode"; out=$(agent_name_check projects/foo gamma-foo-zz); rc=$?
[ "$rc" = 2 ] && [ "$out" = "gamma-foo-zz: an agent of projects/foo is called gamma-rec-<role> [prefix]" ] && ok "name check: a prefix refusal's text and code are printed to the caller (rc 2)" || bad "name check prefix: rc=$rc out=$out"
echo listed > "$HOME/namecheck-mode"; out=$(agent_name_check projects/foo gamma-rec-a gamma-rec-b); rc=$?
[ "$rc" = 3 ] && has "$out" "gamma-rec-a: already on the record: already listed on projects/foo [listed]" && ok "name check: a listed name is \"already ours\" (rc 3), not a refusal" || bad "name check listed: rc=$rc out=$out"
for m in pending hub retired; do
    echo "$m" > "$HOME/namecheck-mode"; out=$(agent_name_check projects/foo gamma-rec-a); rc=$?
    [ "$rc" = 2 ] && has "$out" "[$m]" && ok "name check: code $m is not valid (rc 2), the reason printed" || bad "name check $m: rc=$rc out=$out"
done
rm -f "$HOME/namecheck-mode"
many=(); for i in $(seq 1 25); do many+=("gamma-rec-n$i"); done; : > "$HOME/namecheck-calls.txt"
out=$(agent_name_check projects/foo "${many[@]}"); n=$(cut -d' ' -f2 "$HOME/namecheck-calls.txt" | tr ',' '\n' | wc -l)
[ "$n" = 20 ] && ok "name check: stackshot's 20-name limit is respected (25 candidates, 20 asked)" || bad "name check limit: asked $n"
for m in 404 garbage; do
    echo "$m" > "$HOME/namecheck-mode"; out=$(agent_name_check projects/foo gamma-rec-a gamma-rec-b); rc=$?
    [ "$rc" = 1 ] && [ -z "$out" ] && ok "name check: an answer that is $m (the route is not live): unavailable, nothing printed" || bad "name check $m: rc=$rc out=$out"
done
echo slow > "$HOME/namecheck-mode"; out=$(SALA_AGENT_NAME_TIMEOUT=1 agent_name_check projects/foo gamma-rec-a); rc=$?
[ "$rc" = 1 ] && ok "name check: a timeout is unavailable" || bad "name check slow: rc=$rc"
out=$(SALA_AGENT_NAME_CMD="$HOME/nowhere" agent_name_check projects/foo gamma-rec-a); rc=$?
[ "$rc" = 1 ] && ok "name check: a command that does not exist is unavailable" || bad "name check missing cmd: rc=$rc"
out=$(SALA_AGENT_NAME_CMD="" agent_name_check projects/foo gamma-rec-a); rc=$?
[ "$rc" = 1 ] && ok "name check: an empty command is never asked" || bad "name check empty: rc=$rc"
# --suggest-name uses it: the first candidate stackshot calls invalid is skipped
rm -f "$HOME/namecheck-mode"; : > "$HOME/namecheck-calls.txt"
run --suggest-name --project projects/foo --role back --prefix gamma-rec
n1=$(cut -d' ' -f2 "$HOME/namecheck-calls.txt" | head -1 | cut -d, -f1)
[ "$RC" = 0 ] && [ -n "$n1" ] && [ "$OUT" != "$n1" ] && has "$(cut -d' ' -f2 "$HOME/namecheck-calls.txt" | head -1)" "$OUT" && ok "--suggest-name: skips the candidate stackshot calls invalid and prints the next ($n1 skipped, $OUT)" || bad "suggest with check: rc=$RC out=$OUT calls=$(cat "$HOME/namecheck-calls.txt")"
# with the route not live (404, garbage, no client) the suggestion is sala's own, said calmly
for m in 404 garbage; do
    echo "$m" > "$HOME/namecheck-mode"; run --suggest-name --project projects/foo --role back --prefix gamma-rec
    [ "$RC" = 0 ] && grep -qE '^gamma-rec-[a-z0-9]+$' <<< "$OUT" && ! has "$OUT" "stackshot" && ok "--suggest-name with the check $m: sala's own suggestion, nothing alarming ($OUT)" || bad "suggest fallback $m: rc=$RC — $OUT"
done
SALA_AGENT_NAME_CMD="" run --suggest-name --project projects/foo --role back --prefix gamma-rec
[ "$RC" = 0 ] && grep -qE '^gamma-rec-[a-z0-9]+$' <<< "$OUT" && ok "--suggest-name with no name-check command: sala's own suggestion" || bad "suggest no cmd: rc=$RC — $OUT"
# stackshot ANSWERED and calls none of the candidates valid (taken, a prefix it does not know, a retired, hidden or hub project): no unchecked numbered name comes back,
# stackshot's own reasons are printed and the exit is nonzero; the unavailable cases above keep sala's own suggestion
for m in allbad prefix retired hub pending listed; do
    echo "$m" > "$HOME/namecheck-mode"; run --suggest-name --project projects/foo --role back --prefix gamma-rec
    [ "$RC" != 0 ] && ! grep -qE '^gamma-rec-[a-z0-9]+$' <<< "$OUT" && grep -qE '^   gamma-rec-[a-z0-9]+: ' <<< "$OUT" && has "$OUT" "stackshot answered and calls none of the names it was asked about valid" && ok "--suggest-name, stackshot answers $m for every candidate: no name returned, its reason printed (exit $RC)" || bad "suggest all invalid ($m): rc=$RC — $OUT"
done
echo allbad > "$HOME/namecheck-mode"; run --project projects/foo --role back --mandate "m" --dry-run
[ "$RC" != 0 ] && has "$OUT" "no free agent name for projects/foo" && ok "a spawn with no NAME and no valid candidate stops (nonzero), no unchecked name used" || bad "spawn no name, none valid: rc=$RC — $OUT"
unset SALA_AGENT_NAME_CMD; rm -f "$HOME/namecheck-mode"
unset SALA_STACKSHOT_CLIENT SALA_READBACK_WAIT SALA_READBACK_POLL SALA_PROJECT_RECORD
[ "$(sessions)" = "$S0" ] && ok "the gate section left no session behind" || bad "gate sessions: $(sessions) (was $S0)"

[ "$fail" = 0 ] && echo "spawn: pass" || echo "spawn: FAIL"
exit $fail
