#!/usr/bin/env bash
# The project spawn (Thu Oct 15th 2026; lib/spawn.sh THE MANDATE and A PROJECT AGENT, lib/common.sh THE PROJECT
# SPAWN'S CHECKS, lib/op.sh the spawn verb and THE MANDATE'S TRANSPORT): `spawn NAME --project <page key> --role front|back
# [--mandate FILE|TEXT] [--lane L]`, the one path a web request or `sala op spawn` takes to make a project agent's session.
# What is checked guards a session from being made wrong or unregistered, never the wording of a line: the argument matrix
# refused before anything is asked or made; a missing page (exit 4, `NO-PAGE:`), a "cannot tell" (refused, never fail-open,
# unlike a plain spawn, which keeps its fail-open) and a name not on THAT page's agents map (exit 3, the `ADD-TO-PAGE:` block
# in the shape the pages carry — front top-level, back under `background:`, the mandate's first line cut to 70 characters and
# quoted when YAML needs it — the page's keeper asked once by one stackshot message, not again within the hour, and never
# when a register hook owns registration); a name already live refused with no message; `--dry-run` making, recording and
# calling nothing; the real spawn of a front agent (the orientation line typed with the marker and the absolute path, waiting
# for a confirmation) and of a back agent (starting on it; nobody confirms), the lane row recorded for `--lane`, the register
# hook's arguments and environment, a hook that fails leaving the spawn done; through the queue: the shape refusals with
# nothing queued and no mandate file left, the plan, a TEXT mandate written to its file at queue time (newlines, quotes,
# Japanese, a leading dash kept as bytes) and a FILE passed as it is, a refusal at queue time (exit 3, the block unindented,
# nothing queued, the keeper asked with who heard and the owner's words), the end to end (queued → the unit → the session up reading
# its file → done, the file kept), a conflict on one name, and a line removed between the queue and the run → stuck with no
# claude -p; and, for the side conversation (`spawn NAME --side`), the queue's side: its shape refused at queue time, the plan, the marker's
# arguments, a conflict, the retire gate on a side session without its write-up (the session itself is tests/side.sh); the start directory
# (a back agent with no --cwd starts in the directory SALA_BACK_CWD names, else $HOME when it is unset, and refused when it names a directory that is missing; --cwd wins;
# front, plain and side keep $HOME; the dry run and the pane map show it) and the launch line's Enter (a pane that shows ble.sh's
# "-- MULTILINE --" banner gets one C-j). pages.py is a stub (SALA_AGENT_CHECK_SCRIPT), the stackshot message a stub (SALA_SPAWN_ASK_CMD), the register
# hook a stub, systemd-run / systemctl stubs, the claude -p a stub (never the API), Slack a file; isolated HOME, a private
# tmux socket, the compiled fake claude. No real session, page, message or unit is touched.
# Usage: bash tests/spawn.sh   (exit 0 = pass; ~60 s)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_MASTER SALA_SET SALA_SET_SELF SALA_RECYCLE SALA_RETRY_WORKER SALA_LOCK_WHO SALA_LOCK_WAIT SALA_RELAUNCH_KIND \
      SALA_FLEET_HOSTS SALA_CGROUP_FILE SALA_OP_QUEUE SALA_OP_REBOOT SALA_OP_STUCK SALA_REBOOT_HOOKS SALA_NO_RELAUNCH SALA_SPAWN_REGISTER \
      SALA_AGENT_CHECK SALA_AGENT_CHECK_SCRIPT SALA_BACK_CWD SALA_SPAWN_ASK_CMD SALA_SPAWN_ASK_EVERY SALA_OP_FROM SALA_OP_WORDS SALA_OP_ID SALA_OP_PLAN
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
blockval() { awk -v p="$1" 'index($0, p) == 1 {print substr($0, length(p)+1); exit}' <<< "$2"; }   # <"    name: "> <output> → the YAML value
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

echo "== not listed: exit 3, the ADD-TO-PAGE block in the pages' shape, the keeper asked once by one message and not again within the hour"
run gamma-foo-main --project projects/foo --role front --dry-run
[ "$RC" = 3 ] && has "$OUT" "'gamma-foo-main' is not on the agents map of projects/foo" && ok "a front agent not listed: exit 3" || bad "unlisted front: rc=$RC — $OUT"
[ "$(sed -n '/^ADD-TO-PAGE: /,$p' <<< "$OUT" | grep -v '^   ' | paste -sd'|' -)" = "ADD-TO-PAGE: projects/foo|agents:|  gamma-foo-main: <mandate>" ] && ok "the block: ADD-TO-PAGE: projects/foo / agents: / a top-level entry with <mandate>" || bad "block: $OUT"
waitask gamma-foo-main && A=$(ask gamma-foo-main) && [ "$(sed -n 1p <<< "$A")" = "projects/foo" ] && grep -q -- '^--sender$' <<< "$A" && grep -qx 'sala spawn' <<< "$A" \
    && has "$A" "A new front agent 'gamma-foo-main' of projects/foo was asked for" && [ "$(grep -A1 -x 'agents:' <<< "$A" | tail -1)" = "  gamma-foo-main: <mandate>" ] && ok "one stackshot message to the page key, sender 'sala spawn', the block inside" || bad "ask: $(slurp "$ASKS")"
run gamma-foo-main --project projects/foo --role front --dry-run
[ "$RC" = 3 ] && has "$OUT" "not again within 60 min" && sleep 1 && [ "$(nask gamma-foo-main)" = 1 ] && ok "the same name again: refused again, the keeper not asked again" || bad "second: rc=$RC asks=$(nask gamma-foo-main) — $OUT"
L77="Title: $(printf '%*s' 70 '' | tr ' ' x)"
run gamma-foo-worker --project projects/foo --role back --mandate "# $L77"$'\n'"second line" --dry-run
[ "$RC" = 3 ] && [ "$(sed -n '/^ADD-TO-PAGE: /,$p' <<< "$OUT" | grep -v '^   ' | sed -n 1,3p | paste -sd'|' -)" = "ADD-TO-PAGE: projects/foo|agents:|  background:" ] && grep -q '^    gamma-foo-worker: ' <<< "$OUT" && ok "a back agent: the entry under background:" || bad "back block: $OUT"
[ "$(blockval '    gamma-foo-worker: ' "$OUT")" = "\"${L77:0:70}\"" ] && ok "the mandate line: the heading's # stripped, cut to 70 characters, double-quoted for its ': '" || bad "value: '$(blockval '    gamma-foo-worker: ' "$OUT")'"
waitask gamma-foo-worker && has "$(ask gamma-foo-worker)" "--mandate <the mandate>" && [ "$(grep -A2 -x 'agents:' <<< "$(ask gamma-foo-worker)" | tail -1)" = "    gamma-foo-worker: \"${L77:0:70}\"" ] && ok "a second name: its own message with its block, the mandate's place in the words to say" || bad "worker ask: $(ask gamma-foo-worker)"
K75=$(python3 -c 'print("あ"*75)')
run gamma-foo-k --project projects/foo --role back --mandate "$K75" --dry-run
V=$(blockval '    gamma-foo-k: ' "$OUT"); [ "$RC" = 3 ] && [ "$(python3 -c 'import sys; print(len(sys.argv[1]))' "$V")" = 70 ] && [ "$V" = "${K75:0:70}" ] && ok "a Japanese line is cut at 70 characters, never mid-character" || bad "korean: '$V'"
run gamma-foo-d --project projects/foo --role back --mandate "- a list item" --dry-run; [ "$(blockval '    gamma-foo-d: ' "$OUT")" = '"- a list item"' ] && ok "a leading dash: quoted (a YAML indicator)" || bad "dash: $OUT"
run gamma-foo-p --project projects/foo --role back --mandate "watch the queue" --dry-run; [ "$(blockval '    gamma-foo-p: ' "$OUT")" = 'watch the queue' ] && ok "a plain line: unquoted" || bad "plain: $OUT"
waitask gamma-foo-k && waitask gamma-foo-d && waitask gamma-foo-p && [ "$(nask gamma-foo-k)$(nask gamma-foo-d)$(nask gamma-foo-p)" = 111 ] && ok "each name asked for once" || bad "asks: k=$(nask gamma-foo-k) d=$(nask gamma-foo-d) p=$(nask gamma-foo-p)"
SALA_OP_FROM=sala-test-h SALA_OP_WORDS="make a scout" run gamma-foo-scout --project projects/foo --role back --mandate "scout" --dry-run
waitask gamma-foo-scout && has "$(ask gamma-foo-scout)" "was asked for by sala-test-h (\"make a scout\")" && ok "who heard and the owner's words (SALA_OP_FROM, SALA_OP_WORDS) are in the message" || bad "from/words: $(ask gamma-foo-scout)"
SALA_SPAWN_REGISTER="$HOME/fake-register \"\$@\"" run gamma-foo-hooked --project projects/foo --role front --dry-run
[ "$RC" = 3 ] && has "$OUT" "ADD-TO-PAGE: projects/foo" && sleep 1 && [ "$(nask gamma-foo-hooked)" = 0 ] && grep -q "ask: not sent for projects/foo — SALA_SPAWN_REGISTER is configured" "$SPAWNLOG" && ok "with a register hook configured: refused with the block, nobody asked (registration is the hook's), logged" || bad "hook+unlisted: rc=$RC asks=$(nask gamma-foo-hooked) — $OUT"
SALA_SPAWN_ASK_CMD= run gamma-foo-quiet --project projects/foo --role front --dry-run
[ "$RC" = 3 ] && sleep 1 && [ "$(nask gamma-foo-quiet)" = 0 ] && grep -q "spawn gamma-foo-quiet: ask: not sent for projects/foo — SALA_SPAWN_ASK_CMD is empty" "$SPAWNLOG" && ok "SALA_SPAWN_ASK_CMD set empty: refused, nobody asked, logged" || bad "ask cmd empty: rc=$RC asks=$(nask gamma-foo-quiet) — $(grep gamma-foo-quiet "$SPAWNLOG")"
list projects/bar gamma-foo-main "another page's agent"
run gamma-foo-main --project projects/foo --role front --dry-run; [ "$RC" = 3 ] && has "$OUT" "ADD-TO-PAGE: projects/foo" && ok "listed on another page (projects/bar): not on this one — refused with the block" || bad "other page: rc=$RC — $OUT"
unlist gamma-foo-main
run orphan-x --project projects/foo --role front --dry-run; [ "$RC" = 3 ] && has "$OUT" "nothing to check" && has "$OUT" "ADD-TO-PAGE: projects/foo" && waitask orphan-x && ok "pages.py's 'no project page for this name: nothing to check' (exit 0): not on this page — refused with the block, the keeper asked" || bad "orphan: rc=$RC — $OUT"
run oldorphan-x --project projects/foo --role front --dry-run; [ "$RC" = 3 ] && has "$OUT" "nothing to check" && has "$OUT" "ADD-TO-PAGE: projects/foo" && waitask oldorphan-x && ok "the old 'no steward page … nothing to check' (exit 0) still counts as not on this page" || bad "old orphan: rc=$RC — $OUT"
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
SALA_SPAWN_REGISTER="\"$HOME/fake-register\" \"\$@\"" run gamma-foo-press --project projects/foo --role front --prompt "hello: there" --cwd "$HOME"
rm -f "$HOME/reg-fail"
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

echo "== the queue, a refusal at queue time: not listed → exit 3 with the block unindented, nothing queued, no file, the keeper asked with who heard and the owner's words; no page → exit 4"
enq spawn gamma-foo-new --project projects/foo --role back --mandate "new work" --from sala-test-h --words "make gamma-foo-new"
[ "$RC" = 3 ] && has "$OUT" "did not pass (exit 3) — nothing queued" && grep -qx 'ADD-TO-PAGE: projects/foo' <<< "$OUT" && grep -qx '    gamma-foo-new: new work' <<< "$OUT" && ok "exit 3, the ADD-TO-PAGE block once more at column 0 (the web layer reads it)" || bad "unlisted at queue: rc=$RC — $OUT"
[ "$(queued)" = 0 ] && [ "$(nmandates)" = 0 ] && ok "nothing queued, the mandate file removed" || bad "left: $(ls "$OPS" "$MANDATES" 2>/dev/null)"
waitask gamma-foo-new && has "$(ask gamma-foo-new)" "was asked for by sala-test-h (\"make gamma-foo-new\")" && [ "$(grep -A2 -x 'agents:' <<< "$(ask gamma-foo-new)" | tail -1)" = "    gamma-foo-new: new work" ] && ok "the keeper asked: who heard, the owner's words, the block" || bad "ask: $(ask gamma-foo-new)"
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
[ "$(nposts 'sala op: spawn gamma-foo-queued')" = 1 ] && has "$(<"$POSTS")" "✅" && [ "$(runs)" = 0 ] && ok "one ✅ post, no claude -p" || bad "posts: $(<"$POSTS"); runs=$(runs)"
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
[ "$(mval "$ID" state)" = stuck ] && has "$(mval "$ID" result)" "exited 3" && has "$(mval "$ID" result)" "no claude -p: only the page's keeper can add the line" && ok "stuck: exited 3, the result says only the keeper can add the line" || bad "late: $(cat "$OPS/$ID.op" "$DONE/$ID.op" 2>/dev/null)"
[ "$(runs)" = 0 ] && [ -z "$(mval "$ID" helper)" ] && ! tmux has-session -t =gamma-foo-late 2>/dev/null && ok "no claude -p, no session made" || bad "runs=$(runs) sessions: $(sessions)"
waitask gamma-foo-late && has "$(ask gamma-foo-late)" "was asked for by sala-test-h (\"spawn late\")" && ok "the keeper asked from the unit, with who heard and the owner's words (SALA_OP_FROM, SALA_OP_WORDS exported by the runner)" || bad "late ask: $(ask gamma-foo-late)"
[ "$(nposts 'sala op: spawn gamma-foo-late')" = 1 ] && has "$(<"$POSTS")" "🚨" && ok "one 🚨 post" || bad "posts: $(<"$POSTS")"
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
[ "$RC" = 3 ] && has "$OUT" "'gamma-bar-main' is not on the agents map of projects/foo" && has "$OUT" "main agent: gamma-rec-main" && has "$OUT" "ADD-TO-PAGE: projects/foo" && [ "$(ncalls)" = 0 ] && ok "another project's agent: not listed on this one - exit 3, ADD-TO-PAGE, the project's -main agent named, pages.py not called" || bad "unlisted: rc=$RC calls=$(ncalls) — $OUT"
has "$OUT" "client.py post project-agent projects/foo gamma-bar-main --role <role> --front" && ok "the refusal names stackshot's register path (post project-agent) in words" || bad "register hint: $OUT"
waitask gamma-bar-main && A=$(ask gamma-bar-main) && has "$A" "client.py post project-agent projects/foo gamma-bar-main --role <role> --front --mandate" && [ "$(grep -A1 -x 'agents:' <<< "$A" | tail -1)" = "  gamma-bar-main: <mandate>" ] && ok "the keeper's message carries the block and the register path (words only)" || bad "ask text: $A"
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
run gamma-foo-zzz --dry-run; [ "$RC" = 3 ] && has "$OUT" "ADD-TO-PAGE: projects/foo" && ok "a plain spawn of an unlisted name: the page is read from the current refusal wording" || bad "plain unlisted: rc=$RC — $OUT"
run oldfmt-zzz --dry-run; [ "$RC" = 3 ] && has "$OUT" "ADD-TO-PAGE: projects/foo" && ok "a plain spawn of an unlisted name: the page is read from the old '(steward …' wording too" || bad "plain unlisted, old wording: rc=$RC — $OUT"
rm -f "$SALA_PROJECT_RECORD"; agent_unlisted gamma-rec-worker >/dev/null; rc=$?; [ "$rc" = 0 ] && ok "no record: pages.py's answer is used (it does not list the name)" || bad "no record: rc=$rc"
unset SALA_PROJECT_RECORD

[ "$fail" = 0 ] && echo "spawn: pass" || echo "spawn: FAIL"
exit $fail
