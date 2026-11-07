#!/usr/bin/env bash
# `sala rename` has stackshot rename OLD's entry on the project's page in place, and a status it cannot read is unknown, not busy (
# Tue Oct 27th 2026; lib/rename.sh, lib/common.sh "THE RENAME RENAMES ITS ENTRY"). Until then a NEW its project's page did not list was refused
# (only the page's keeper could unblock it) and a pane whose registry row gave no status was waited on for 2 h. Isolated HOME, a private tmux
# socket, the compiled fake claude (tests/fake-claude.c). pages.py is a stub (SALA_AGENT_CHECK_SCRIPT) that answers in pages.py's own words, the
# project record a file in the contract's schema, and stackshot's client.py a stub (SALA_STACKSHOT_CLIENT) that logs its arguments and answers
# in the real client's words per mode: no network, no stackshot write, no real pane. Cases: a dry run prints the plan and calls nothing; "renamed"
# (the call is `post project-agent-rename <hub> OLD NEW --sender sala-rename`, nothing else) and the rename goes on; "already renamed" is
# taken only as the retry of a rename sala started (after an unreached call) and refused otherwise; 409, 404, 403 and an unreachable stackshot
# are refusals that rename nothing (tmux session and pane map unchanged); no client, and a hand rename (--sync), never call; an unreadable
# status goes ahead, a busy one is still named. The spawn window: a session whose spawn has not landed its pane-map row yet (a young
# session, or a spawn operation in flight) is waited for, its registry entry and its row on one budget; any other session without them, and
# --sync, is refused at once (exit 4 for the row). A side spawn's .side file lands later still, and the side-or-in-place decision waits for it on
# the same budget (the last section: lands 3 s late = the side plan; never = the in-place plan after the wait; a non-side session and --sync
# never wait; the spawn operation's own --side decides over the name).
# A SIDE SESSION renamed to an agent name (the last section): with a side record the rename lists NEW through `post project-agent
# <project> NEW --role R --front --mandate L --sender sala-web` (the stub's client-mode-agent: recorded, 403, 400, 409, unreachable) and then ends
# the record (side/retired/, registry side fields cleared, row tagged project / front); a refusal renames nothing and keeps the record; no project
# on the record or its origin is refused in --dry-run; the origin's project is the fallback; an already listed NEW makes no call; --sync never calls.
# A --dry-run run directly inside OLD's own pane (TMUX_PANE set) says nothing is typed (a pane cannot type into itself) and names the queued
# `sala op rename` path that types from outside; with no TMUX_PANE, as the queue's unit runs it, the plan types /rename itself.
# Usage: bash tests/rename.sh   (exit 0 = pass; ~40 s)
set -u
unset TMUX_PANE XDG_STATE_HOME
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null
as_op_unit
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect" "$HOME/work"
touch "$HOME/.claude/salamander-rc.stopped"
cc -o "$HOME/.local/bin/claude" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (an EXIT trap may not exist yet here)
export PATH="$HOME/.local/bin:$PATH"; export FAKE_LOG="$HOME/fake.log"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="cat >> $POSTS"
export SALA_AUTO_UPDATE=off SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT"
SALA="$ROOT/bin/salamander"; SOCK="sala-rename-$$"; T="tmux -L $SOCK -f /dev/null"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"
RP=""
cleanup() {
    local f p
    [ -n "$RP" ] && kill "$RP" 2>/dev/null
    for f in "$HOME"/.claude/salamander-retry*.pid; do [ -s "$f" ] && kill "$(<"$f")" 2>/dev/null; done
    $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    for p in $(pgrep -x claude); do [ "$HOME/.local/bin/claude" -ef "/proc/$p/exe" ] && kill -9 "$p" 2>/dev/null; done   # only our fakes
    rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
U1=aaaaaaaa-0000-4000-8000-000000000001 U2=aaaaaaaa-0000-4000-8000-000000000002 U3=aaaaaaaa-0000-4000-8000-000000000003
U4=aaaaaaaa-0000-4000-8000-000000000004 U5=aaaaaaaa-0000-4000-8000-000000000005 U6=aaaaaaaa-0000-4000-8000-000000000006
U7=aaaaaaaa-0000-4000-8000-000000000007 U8=aaaaaaaa-0000-4000-8000-000000000008 U9=aaaaaaaa-0000-4000-8000-000000000009
U10=aaaaaaaa-0000-4000-8000-00000000000a U11=aaaaaaaa-0000-4000-8000-00000000000b
TYPED="$HOME/typed.log"; CALLS="$HOME/client-calls.txt"
row() { awk -F'\t' -v s="$1" '$1==s' "$MAP" 2>/dev/null; }
regfile() { echo "$HOME/.claude/sessions/$(claude_pid_under "$(tmux display -p -t "$1" '#{pane_pid}')").json"; }
hand() { $T new-session -d -s "$1" -c "$3" -e FAKE_SESSION_ID="$2" -e FAKE_NAME="$1" -e FAKE_LOG="$FAKE_LOG" -e FAKE_TYPED_LOG="$TYPED"; $T send-keys -t "$1" 'claude' Enter; }
setname() { python3 - "$(regfile "$1")" "$2" <<'PY'
import json, sys; p = sys.argv[1]; d = json.load(open(p)); d["name"] = sys.argv[2]; json.dump(d, open(p, "w"))
PY
}
dropstatus() { python3 - "$(regfile "$1")" "$2" <<'PY'
import json, sys; p = sys.argv[1]; d = json.load(open(p))
if sys.argv[2] == "drop": d.pop("status", None)
else: d["status"] = sys.argv[2]
json.dump(d, open(p, "w"))
PY
}
calls() { local n=0 l; [ -r "$CALLS" ] || { echo 0; return; }; { while IFS= read -r l || [ -n "$l" ]; do n=$((n + 1)); done < "$CALLS"; } 2>/dev/null; echo "$n"; }

# stackshot's side, stubbed. pages.py: a name in listed.txt (key TAB name TAB line) is listed, any gamma-foo-* name is not and the refusal is pages.py's
# own line (hub page and project name in it); the project record: only gamma-foo-main (so no test name is listed by it);
# client.py: logs its arguments (one line, fields split by \x1f) and answers in the real client's words per mode in $HOME/client-mode:
# renamed (default; moves the entry in listed.txt), already (200 "already renamed"), 409, 404, 403, unreachable ([0]), garbage (exit 0, not JSON)
cat > "$HOME/fake-pages.py" <<'PY'
import os, sys
home = os.environ["HOME"]; cmd = sys.argv[1]; arg = sys.argv[2] if len(sys.argv) > 2 else ""
if cmd == "agent-listed":
    listed = {}
    try:
        for ln in open(home + "/listed.txt"):
            if ln.strip(): k, n, m = ln.rstrip("\n").split("\t"); listed[n] = (k, m)
    except FileNotFoundError: pass
    if arg in listed: print(f"listed on {listed[arg][0]}: {listed[arg][1]}"); sys.exit(0)
    if arg.startswith("gamma-foo-"):
        print(f"not listed: {arg} is not under `agents:` on projects/foo (the page whose `display-name:` line is gamma-foo). The line `{arg}: <mandate>` has to be added there first (ask the project's -main agent), then the session can be made."); sys.exit(3)
    print("no project page for this name: nothing to check"); sys.exit(0)
sys.exit(1)
PY
cat > "$HOME/fake-client.py" <<'PY'
import json, os, sys
home = os.environ["HOME"]
open(home + "/client-calls.txt", "a").write("\x1f".join(sys.argv[1:]) + "\n")
mode = open(home + "/client-mode").read().strip() if os.path.exists(home + "/client-mode") else "renamed"
a = sys.argv[1:]
if a[:2] == ["post", "project-agent"]:   # a side session becoming an agent: the real client prints its refusals on stdout, exit 1
    amode = open(home + "/client-mode-agent").read().strip() if os.path.exists(home + "/client-mode-agent") else "recorded"
    project, name = a[2], a[3]
    arefusals = {"403": f"stackshot: agent not listed [403] refused: {project} is hidden, not listed. List it again first with `client.py post project-list --key {project}`, then add the agent",
                 "400": f"stackshot: agent not listed [400] {name!r} does not start with the project's name: an agent of {project} is called gamma-foo-<role>",
                 "409": f"stackshot: agent not listed [409] {name} was already registered for {project} by another session (x) and its page line is still owed",
                 "unreachable": "stackshot: agent not listed [0] URLError: <urlopen error [Errno 111] Connection refused>"}
    if amode in arefusals: print(arefusals[amode]); sys.exit(1)
    mand = a[a.index("--mandate") + 1] if "--mandate" in a else ""
    open(home + "/listed.txt", "a").write("%s\t%s\t%s\n" % (project, name, mand))   # the project record lists it (page_owed) from here on
    print(f"Recorded in prj_example ({project}) in stackshot's record only: the page line is still owed. Add `{name}: {mand}` under `agents:`")
    sys.exit(0)
if a[:2] != ["post", "project-agent-rename"] or len(a) < 5: print("usage: client.py post project-agent-rename <project> <OLD> <NEW> [--sender <label>]", file=sys.stderr); sys.exit(1)
project, old, new = a[2], a[3], a[4]
refusals = {"409": f"stackshot: agent not renamed [409] {new} is already listed on {project}",
            "404": f"stackshot: agent not renamed [404] {old} is not listed on {project}",
            "403": "stackshot: agent not renamed [403] refused: only the web form may rename an agent's entry on a page: `sender` must be a label in [project_agent] form_senders and the token must be a machine in form_machines",
            "unreachable": "stackshot: agent not renamed [0] URLError: <urlopen error [Errno 111] Connection refused>"}
if mode in refusals: print(refusals[mode], file=sys.stderr); sys.exit(1)
if mode == "garbage": print("<html>not json</html>"); sys.exit(0)
front = old != "sala-test-o2"
role = new.split("-", 2)[2] if new.count("-") >= 2 else "?"
line = "builds the foo things" if front else "watches the foo inbox"
if mode == "renamed": open(home + "/listed.txt", "a").write("%s\t%s\t%s\n" % (project, new, line))
print(json.dumps({"project": "prj_example", "key": project, "result": "renamed" if mode == "renamed" else "already renamed", "old": old, "new": new,
                  "front": front, "role": role, "mandate": line, "note": "stub"}))
PY
python3 - "$HOME/projects.json" <<'PY'
import datetime, json, sys
d = {"schema": 1, "generated": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
     "projects": {"prj_example": {"id": "prj_example", "key": "projects/foo", "keeper": "gamma-foo-main", "agents": {
         "gamma-foo-main": {"front": True, "role": "main", "mandate_line": "the front door"}}}},
     "by_key": {"projects/foo": "prj_example"}}
json.dump(d, open(sys.argv[1], "w"))
PY
export SALA_AGENT_CHECK_SCRIPT="$HOME/fake-pages.py" SALA_PROJECT_RECORD="$HOME/projects.json" SALA_STACKSHOT_CLIENT="$HOME/fake-client.py"
unset SALA_AGENT_CHECK SALA_RENAME_SENDER
mode() { printf '%s\n' "$1" > "$HOME/client-mode"; }
untouched() { tmux has-session -t "=$1" 2>/dev/null && ! tmux has-session -t "=$2" 2>/dev/null && [ "$(slurp "$MAP")" = "$MAP_BEFORE" ]; }   # <OLD> <NEW>: the rename changed nothing
refused() {  # <label> <OLD> <NEW> <expected text>: runs the rename, expects a refusal naming the text, one stackshot call, nothing changed
    local n0 out rc; n0=$(calls); MAP_BEFORE=$(slurp "$MAP")
    out=$("$SALA" rename "$2" "$3" 2>&1); rc=$?
    echo "$out" | sed 's/^/    /' | cut -c1-300
    [ "$rc" != 0 ] && has "$out" "rename refused, nothing renamed: " && has "$out" "$4" && [ "$(calls)" = $((n0 + 1)) ] && untouched "$2" "$3" \
        && ok "$1: refused with stackshot's reason, one call, tmux session and pane map unchanged" || bad "$1: rc=$rc calls=$(calls) (was $n0)"
}

echo "== setup: six sessions made by hand and adopted (o3 is the one the refusals are tried on)"
for i in 1 2 3 4 5 6; do eval "u=\$U$i"; hand sala-test-o$i "$u" "$HOME/work"; done; fake_up sala-test-o1 sala-test-o2 sala-test-o3 sala-test-o4 sala-test-o5 sala-test-o6
. "$ROOT/lib/common.sh"; MAP="$SALA_SIDECAR"
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux
for i in 1 2 3 4 5 6; do "$SALA" adopt sala-test-o$i >/dev/null 2>&1; done
[ "$(wc -l < "$MAP")" = 6 ] && ok "six rows in the pane map" || bad "map: $(slurp "$MAP")"
MAP_BEFORE=$(slurp "$MAP")

echo "== --dry-run: says what it would ask stackshot, calls nothing, writes nothing"
setname sala-test-o1 gamma-foo-hosting
out=$("$SALA" rename sala-test-o1 gamma-foo-hosting --dry-run 2>&1); rc=$?
echo "$out" | sed 's/^/    /'
[ "$rc" = 0 ] && has "$out" "rename 'sala-test-o1' to 'gamma-foo-hosting' on projects/foo's page, in place (stackshot: post project-agent-rename, label sala-rename)" \
    && ok "the plan names the page, the call and the label" || bad "dry run: rc=$rc"
[ "$(calls)" = 0 ] && [ ! -e "$HOME/listed.txt" ] && ok "no stackshot call made" || bad "calls: $(slurp "$CALLS")"
untouched sala-test-o1 gamma-foo-hosting && ok "tmux session and pane map untouched" || bad "after the dry run: $(tmux ls 2>&1 | head -3) / $(slurp "$MAP")"

echo "== --dry-run run directly inside OLD's own pane (TMUX_PANE set): the self text says what is true; run from outside it, the runner's line"
O1PANE=$(tmux display -p -t sala-test-o1 '#{pane_id}')
out=$(TMUX_PANE="$O1PANE" "$SALA" rename sala-test-o1 gamma-foo-selfcase --dry-run 2>&1); rc=$?
echo "$out" | sed 's/^/    /'
[ "$rc" = 0 ] && has "$out" "a direct run inside this pane, which cannot type into itself: nothing typed" && has "$out" "/rename gamma-foo-selfcase has to be typed in the pane by hand if it is not 'gamma-foo-selfcase' yet" \
    && has "$out" 'a queued `sala op rename sala-test-o1 gamma-foo-selfcase` types it from outside once the pane is idle' && ! has "$out" "type /rename gamma-foo-selfcase here yourself" && ! has "$out" "it is this pane" && ! has "$out" "type /rename gamma-foo-selfcase (pane now:" \
    && ok "a direct run in the pane: nothing typed, the text names the hand step and the queued path that types from outside" || bad "self dry run: rc=$rc — $out"
out=$("$SALA" rename sala-test-o1 gamma-foo-selfcase --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && has "$out" "type /rename gamma-foo-selfcase (pane now:" && ! has "$out" "cannot type into itself" \
    && ok "the same dry run with no TMUX_PANE (the queue runner's): it types /rename itself" || bad "runner dry run: rc=$rc — $out"
[ "$(calls)" = 0 ] && untouched sala-test-o1 gamma-foo-hosting && ok "still no call, nothing changed" || bad "after the self dry runs: $(slurp "$CALLS") / $(slurp "$MAP")"

echo "== the note store is relabeled through a scratch file that never stays in TMPDIR"
SCR="$HOME/scratch"; mkdir -p "$SCR" "$HOME/failawk"; NOTES_F="$SALA_LOG_DIR/salamander-notes.tsv"
printf '1\tsala-test-o1\t%s\t2026-01-01T00:00:00Z\t0\t-\t-\tremember this\n2\tsala-test-o2\t%s\t2026-01-01T00:00:00Z\t0\t-\t-\tand this\n' "$U1" "$U2" > "$NOTES_F"
printf '#!/bin/sh\ncase "$*" in *salamander-notes*) exit 1 ;; esac\nexec %s "$@"\n' "$(command -v awk)" > "$HOME/failawk/awk"; chmod +x "$HOME/failawk/awk"   # fails only on the note store
scratch_left() { ls -A "$SCR" 2>/dev/null | tr '\n' ' '; }

echo "== renamed: stackshot renames OLD's entry in place and the rename goes on"
out=$(TMPDIR="$SCR" "$SALA" rename sala-test-o1 gamma-foo-hosting 2>&1); rc=$?
echo "$out" | sed 's/^/    /' | cut -c1-230
[ "$rc" = 0 ] && has "$out" "✅ 'sala-test-o1' is now 'gamma-foo-hosting'" && ok "renamed (rc 0)" || bad "rename: rc=$rc"
[ "$(calls)" = 1 ] && [ "$(slurp "$CALLS")" = $'post\x1fproject-agent-rename\x1fprojects/foo\x1fsala-test-o1\x1fgamma-foo-hosting\x1f--sender\x1fsala-rename' ] \
    && ok "one call: post project-agent-rename projects/foo sala-test-o1 gamma-foo-hosting --sender sala-rename (no role, side or line sent)" || bad "client calls: $(slurp "$CALLS" | tr '\037' ' ')"
has "$out" "'sala-test-o1' is now 'gamma-foo-hosting' on projects/foo's page (stackshot, in place): front agent, role hosting, line: builds the foo things" && ok "the output says what stackshot answered" || bad "no rename note"
tmux has-session -t =gamma-foo-hosting 2>/dev/null && [ -n "$(row gamma-foo-hosting)" ] && [ -z "$(row sala-test-o1)" ] && ok "tmux session and map row follow the name" || bad "after the rename: $(slurp "$MAP")"
awk -F'\t' -v u="$U1" '$3==u {print $2}' "$NOTES_F" | grep -qx gamma-foo-hosting && [ -z "$(scratch_left)" ] && ok "the open note follows the new name and the relabel left TMPDIR empty" || bad "note row: $(slurp "$NOTES_F" | head -2); TMPDIR holds: $(scratch_left)"

echo "== a background entry, and SALA_RENAME_SENDER as the label"
setname sala-test-o2 gamma-foo-watch-2
out=$(TMPDIR="$SCR" PATH="$HOME/failawk:$PATH" SALA_RENAME_SENDER=other-label "$SALA" rename sala-test-o2 gamma-foo-watch-2 2>&1); rc=$?   # the note store's awk fails here
last=$(tail -1 "$CALLS" | tr '\037' ' ')
[ -z "$(scratch_left)" ] && has "$out" "the note store was locked" && ok "the relabel's awk failing: the rename goes on, the scratch file is not left in TMPDIR" || bad "after a failed relabel TMPDIR holds: $(scratch_left); out: $out"
[ "$rc" = 0 ] && [ "$last" = "post project-agent-rename projects/foo sala-test-o2 gamma-foo-watch-2 --sender other-label" ] && has "$out" "background agent, role watch-2, line: watches the foo inbox" \
    && ok "label other-label; stackshot's answer (background) is relayed" || bad "back agent: rc=$rc $last"

echo "== refusals: 409, 404, 403, an unreachable stackshot, an answer that is not JSON: nothing renamed each time"
setname sala-test-o3 gamma-foo-baz; setname sala-test-o4 gamma-foo-qux
mode 409; refused "409 (NEW is already listed)" sala-test-o4 gamma-foo-qux "stackshot: agent not renamed [409] gamma-foo-qux is already listed on projects/foo"
mode 404; refused "404 (OLD is not listed)" sala-test-o3 gamma-foo-baz "stackshot: agent not renamed [404] sala-test-o3 is not listed on projects/foo"
mode 403; refused "403 (not the form)" sala-test-o4 gamma-foo-qux "stackshot: agent not renamed [403] refused: only the web form may rename an agent's entry on a page"
mode garbage; refused "exit 0 but not JSON" sala-test-o3 gamma-foo-baz "unreadable answer"
mode unreachable; refused "stackshot unreachable" sala-test-o4 gamma-foo-qux "[0] URLError"
[ -s "$SALA_STATE_DIR/rename-listed.tsv" ] && grep -q "sala-test-o4.gamma-foo-qux" "$SALA_STATE_DIR/rename-listed.tsv" && ! grep -q "sala-test-o3" "$SALA_STATE_DIR/rename-listed.tsv" \
    && ok "only the unreached call is remembered as started (its outcome is unknown); the clear refusals are not" || bad "marker file: $(slurp "$SALA_STATE_DIR/rename-listed.tsv" 2>&1)"

echo "== already renamed: success only for a rename sala started (the retry after the unreached call), refused otherwise"
mode already; refused "already renamed, not started here" sala-test-o3 gamma-foo-baz "this machine did not start that rename"
n0=$(calls)
out=$("$SALA" rename sala-test-o4 gamma-foo-qux 2>&1); rc=$?
echo "$out" | sed 's/^/    /' | cut -c1-260
[ "$rc" = 0 ] && has "$out" "'gamma-foo-qux' was already listed on projects/foo's page in place of 'sala-test-o4' (stackshot: already renamed): taken as the retry of the rename sala started earlier" \
    && has "$out" "✅ 'sala-test-o4' is now 'gamma-foo-qux'" && [ "$(calls)" = $((n0 + 1)) ] && tmux has-session -t =gamma-foo-qux 2>/dev/null && ok "the retry goes on, and the log line says it was taken as a retry" || bad "already renamed retry: rc=$rc"
mode renamed

echo "== no client: refused, naming it; a hand rename (--sync) is followed, never calls stackshot"
n0=$(calls); MAP_BEFORE=$(slurp "$MAP")
out=$(SALA_STACKSHOT_CLIENT="$HOME/nowhere.py" SALA_STACKSHOT_DIR= "$SALA" rename sala-test-o3 gamma-foo-baz 2>&1); rc=$?
[ "$rc" != 0 ] && has "$out" "no stackshot client.py on this box" && [ "$(calls)" = "$n0" ] && untouched sala-test-o3 gamma-foo-baz && ok "no client.py: refused, naming it, nothing changed" || bad "no client: rc=$rc $out"
setname sala-test-o6 gamma-foo-hand
out=$(SALA_RENAME_SYNC=1 "$SALA" rename sala-test-o6 gamma-foo-hand 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(calls)" = "$n0" ] && tmux has-session -t =gamma-foo-hand 2>/dev/null && ok "followed, no call" || bad "sync: rc=$rc $out"

echo "== a status that cannot be read is unknown, not busy: it goes ahead"
dropstatus sala-test-o5 busy
out=$("$SALA" rename sala-test-o5 gamma-foo-nu --dry-run 2>&1)
has "$out" "registry says 'busy'" && ok "a busy pane is still named busy in the plan" || bad "busy plan: $out"
dropstatus sala-test-o5 drop
out=$("$SALA" rename sala-test-o5 gamma-foo-nu --dry-run 2>&1)
has "$out" "status unknown, not busy: it would go ahead as for an idle pane" && ok "the plan says unknown, would go ahead" || bad "unknown plan: $out"
: > "$TYPED"
( "$SALA" rename sala-test-o5 gamma-foo-nu > "$HOME/unknown.out" 2>&1; echo $? > "$HOME/unknown.rc" ) &
RP=$!
waitfor "grep -q ' /rename gamma-foo-nu\$' '$TYPED'" 60 && ok "/rename typed into the pane, without waiting for a status" || bad "nothing typed: $(typed_ctx "$TYPED") / $(slurp "$HOME/unknown.out")"
setname sala-test-o5 gamma-foo-nu   # what the CLI does once it takes /rename
wait "$RP"; RP=""
out=$(slurp "$HOME/unknown.out"); echo "$out" | sed 's/^/    /' | cut -c1-200
has "$out" "'sala-test-o5' reports no status (unknown, not busy): going ahead as for an idle pane" && ok "the note is printed" || bad "no unknown note"
[ "$(slurp "$HOME/unknown.rc")" = 0 ] && has "$out" "✅ 'sala-test-o5' is now 'gamma-foo-nu'" && ! has "$out" "retrying every minute" && ok "renamed at once: no 2 h retry worker" || bad "unknown status: rc=$(slurp "$HOME/unknown.rc")"

# rename_late <needle> <landing command> <command…>: what a spawn does late (lands a row, a registry file, a side record) is done only once the
# rename has said it is waiting. The command (a rename) runs in the background with its output in a file; the landing runs 2.5 s after <needle>
# shows in the file (so the rename really waited, whatever the load), then the command is waited for. Sets out, rc and el (start to finish).
# A fixed `( sleep 3; land ) &` raced a rename that started late on a loaded box: the landing came first, no wait line was printed (seen in CI).
_has_line() { grep -qF -- "$1" "$2" 2>/dev/null; }   # <needle> <file>
rename_late() {
    local needle=$1 land=$2 f="$HOME/late.out" pid seen=0; shift 2
    : > "$f"; SECONDS=0
    "$@" > "$f" 2>&1 & pid=$!
    waitfor '_has_line "$needle" "$f" || ! kill -0 "$pid" 2>/dev/null' 120
    _has_line "$needle" "$f" && { seen=1; nap 2.5; }
    eval "$land"
    wait "$pid"; rc=$?; el=$SECONDS; out=$(<"$f"); rm -f "$f"
    [ "$seen" = 1 ] || out="(the rename never printed its waiting line: $needle) $out"
}

echo "== the spawn window: a session whose spawn has not landed its pane-map row yet is waited for; any other session without a row is refused at once"
# (a) a young session, its row lands 2.5 s after the rename says it waits (what a spawn does on its way out): the rename waits, then goes ahead.
hand sala-test-w1 "$U7" "$HOME/work"; fake_up sala-test-w1; setname sala-test-w1 gamma-foo-w1
rename_late "… waiting for the spawn of 'sala-test-w1' to land its pane-map row" '"$SALA" adopt sala-test-w1 >/dev/null 2>&1' "$SALA" rename sala-test-w1 gamma-foo-w1
echo "$out" | sed 's/^/    /' | cut -c1-200
[ "$rc" = 0 ] && has "$out" "… waiting for the spawn of 'sala-test-w1' to land its pane-map row" && [ "$el" -ge 2 ] && tmux has-session -t =gamma-foo-w1 2>/dev/null && [ -n "$(row gamma-foo-w1)" ] \
    && ok "young session, row landed after ~3 s: waited (${el} s), then renamed (tmux session and map row follow)" || bad "young session, row lands: rc=$rc after ${el} s"
# (b) a young session with no row: refused with exit 4 after SALA_RENAME_MAP_WAIT (2 s here); the dry run waits the same way
hand sala-test-w2 "$U8" "$HOME/work"; fake_up sala-test-w2; setname sala-test-w2 gamma-foo-w2
MAP_BEFORE=$(slurp "$MAP")
SECONDS=0; out=$(SALA_RENAME_MAP_WAIT=2 "$SALA" rename sala-test-w2 gamma-foo-w2 2>&1); rc=$?; el=$SECONDS
echo "$out" | sed 's/^/    /' | cut -c1-200
[ "$rc" = 4 ] && has "$out" "… waiting for the spawn of 'sala-test-w2' to land its pane-map row" && has "$out" "'sala-test-w2' is not in the pane map" && [ "$el" -ge 2 ] && [ "$el" -lt "$(scale 15)" ] \
    && untouched sala-test-w2 gamma-foo-w2 && ok "young session, no row: refused with exit 4 after the wait (${el} s), nothing changed" || bad "young session, no row: rc=$rc after ${el} s"
SECONDS=0; out=$(SALA_RENAME_MAP_WAIT=2 "$SALA" rename sala-test-w2 gamma-foo-w2 --dry-run 2>&1); rc=$?; el=$SECONDS
[ "$rc" = 4 ] && has "$out" "… waiting for the spawn of 'sala-test-w2'" && [ "$el" -ge 2 ] && ok "the dry run (sala op --plan) waits the same way" || bad "dry run: rc=$rc after ${el} s: $out"
# (c) an old session (older than SALA_RENAME_YOUNG, 1 s here) with no row, no spawn operation: refused at once, no wait line
hand sala-test-w3 "$U9" "$HOME/work"; fake_up sala-test-w3; setname sala-test-w3 gamma-foo-w3; sleep 2
SECONDS=0; out=$(SALA_RENAME_YOUNG=1 SALA_RENAME_MAP_WAIT=30 "$SALA" rename sala-test-w3 gamma-foo-w3 2>&1); rc=$?; el=$SECONDS
echo "$out" | sed 's/^/    /' | cut -c1-200
[ "$rc" = 4 ] && has "$out" "'sala-test-w3' is not in the pane map" && ! has "$out" "waiting for the spawn" && [ "$el" -lt "$(scale 6)" ] \
    && ok "old session, no row: refused at once (exit 4, ${el} s, no wait)" || bad "old session: rc=$rc after ${el} s"
# (d) --sync (SALA_RENAME_SYNC=1) never waits, young session or not (it relies on exit 4 being fast)
SECONDS=0; out=$(SALA_RENAME_SYNC=1 SALA_RENAME_MAP_WAIT=30 "$SALA" rename sala-test-w2 gamma-foo-w2 2>&1); rc=$?; el=$SECONDS
[ "$rc" = 4 ] && ! has "$out" "waiting for the spawn" && [ "$el" -lt "$(scale 6)" ] && ok "--sync: refused at once on a young session (exit 4, ${el} s)" || bad "sync: rc=$rc after ${el} s"
# (e) a spawn operation in flight for the name (the marker op.sh writes) is waited for however old the session is; a finished one is not
mkdir -p "$SALA_STATE_DIR/ops"; OPF="$SALA_STATE_DIR/ops/1-1.op"
printf 'id=1-1\nverb=spawn\narg=sala-test-w3\narg=--project\narg=projects/foo\nstate=running\n' > "$OPF"
SECONDS=0; out=$(SALA_RENAME_YOUNG=1 SALA_RENAME_MAP_WAIT=2 "$SALA" rename sala-test-w3 gamma-foo-w3 2>&1); rc=$?; el=$SECONDS
[ "$rc" = 4 ] && has "$out" "… waiting for the spawn of 'sala-test-w3'" && [ "$el" -ge 2 ] && ok "a running spawn operation for the name: waited, then the same refusal" || bad "spawn marker: rc=$rc after ${el} s"
sed -i 's/^state=running/state=done/' "$OPF"
SECONDS=0; out=$(SALA_RENAME_YOUNG=1 SALA_RENAME_MAP_WAIT=30 "$SALA" rename sala-test-w3 gamma-foo-w3 2>&1); rc=$?; el=$SECONDS
[ "$rc" = 4 ] && ! has "$out" "waiting for the spawn" && [ "$el" -lt "$(scale 6)" ] && ok "a finished spawn operation does not count: refused at once" || bad "done marker: rc=$rc after ${el} s"
rm -f "$OPF"

echo "== the same window one step earlier: the claude is up but its registry entry has not landed (the file is hidden, then put back)"
# (f) a young, mapped session whose registry entry lands 3 s late: the rename waits for it (one shared budget), then goes ahead
hand sala-test-w4 "$U10" "$HOME/work"; fake_up sala-test-w4; setname sala-test-w4 gamma-foo-w4; "$SALA" adopt sala-test-w4 >/dev/null 2>&1
RF4=$(regfile sala-test-w4); mv "$RF4" "$RF4.hold"
rename_late "… waiting for the spawn of 'sala-test-w4' to land its registry entry" 'mv "$RF4.hold" "$RF4"' "$SALA" rename sala-test-w4 gamma-foo-w4
echo "$out" | sed 's/^/    /' | cut -c1-200
[ "$rc" = 0 ] && has "$out" "… waiting for the spawn of 'sala-test-w4' to land its registry entry" && [ "$el" -ge 2 ] && tmux has-session -t =gamma-foo-w4 2>/dev/null && [ -n "$(row gamma-foo-w4)" ] \
    && ok "registry entry landed after ~3 s: waited (${el} s), then renamed" || bad "registry lands late: rc=$rc after ${el} s"
# (g) a young session that never gets an entry: refused after SALA_RENAME_MAP_WAIT (2 s), with the same message
hand sala-test-w5 "$U11" "$HOME/work"; fake_up sala-test-w5; setname sala-test-w5 gamma-foo-w5
RF5=$(regfile sala-test-w5); mv "$RF5" "$RF5.hold"
SECONDS=0; out=$(SALA_RENAME_MAP_WAIT=2 "$SALA" rename sala-test-w5 gamma-foo-w5 2>&1); rc=$?; el=$SECONDS
echo "$out" | sed 's/^/    /' | cut -c1-200
[ "$rc" != 0 ] && has "$out" "… waiting for the spawn of 'sala-test-w5' to land its registry entry" && has "$out" "no registry entry for 'sala-test-w5' (pid " && [ "$el" -ge 2 ] && [ "$el" -lt "$(scale 15)" ] \
    && ok "young session, no entry: refused after the wait (${el} s), same message" || bad "no entry, young: rc=$rc after ${el} s"
# (h) an old session with no entry: refused at once, no wait line; (i) --sync never waits
SECONDS=0; out=$(SALA_RENAME_YOUNG=1 SALA_RENAME_MAP_WAIT=30 "$SALA" rename sala-test-w5 gamma-foo-w5 2>&1); rc=$?; el=$SECONDS
[ "$rc" != 0 ] && has "$out" "no registry entry for 'sala-test-w5' (pid " && ! has "$out" "waiting for the spawn" && [ "$el" -lt "$(scale 6)" ] && ok "old session, no entry: refused at once (${el} s, no wait)" || bad "no entry, old: rc=$rc after ${el} s"
SECONDS=0; out=$(SALA_RENAME_SYNC=1 SALA_RENAME_MAP_WAIT=30 "$SALA" rename sala-test-w5 gamma-foo-w5 2>&1); rc=$?; el=$SECONDS
[ "$rc" != 0 ] && has "$out" "no registry entry for 'sala-test-w5' (pid " && ! has "$out" "waiting for the spawn" && [ "$el" -lt "$(scale 6)" ] && ok "--sync: refused at once on a young session (${el} s)" || bad "no entry, sync: rc=$rc after ${el} s"

echo "== a side session renamed to an agent name: NEW is listed through project-agent, then the rename goes on and the side record ends"
# side records are written the way spawn --side writes them (common.sh, THE SIDE SESSIONS); a row's fields are read from the session registry
SU1=aaaaaaaa-0000-4000-8000-000000000021 SU2=aaaaaaaa-0000-4000-8000-000000000022 SU3=aaaaaaaa-0000-4000-8000-000000000023 SU4=aaaaaaaa-0000-4000-8000-000000000024 SU5=aaaaaaaa-0000-4000-8000-000000000025
mkdir -p "$SALA_SIDE_DIR"
sidemake() {  # <name> <project> <origin> → a live side session with its record, mandate file and registry fields
    local head="## Rowan's instructions for this conversation"   # the older heading, still accepted
    case "$1" in sala-test-side-a|sala-test-side-l1) head="## Instructions for this conversation" ;; esac   # the heading spawn writes now
    printf '# Side conversation: %s\n\nYou are a side conversation.\n\n%s\nlook into the foo hosting move\nthen report\n' "$1" "$head" > "$HOME/mandate-$1.md"
    { echo "name=$1"; echo "kind=fork"; echo "origin=$3"; echo "project=$2"; echo "item=board#53"; echo "agents="; echo "summary_to=$3"; echo "started=$(date +%s)"; echo "uuid="; echo "origin_uuid="
      echo "mandate=$HOME/mandate-$1.md"; } > "$(side_file "$1")"
    sessions_set "$1" "side=1" "side_origin=$3" "side_item=board#53" "side_at=2026-10-28T00:00:00Z"
}
rowfield() {  # <name> <field> → the newest live registry row's field of that name (empty when none or null)
    python3 -I - "$SALA_SESSIONS_FILE" "$1" "$2" <<'PY'
import json, sys
try: rows = [r for r in json.load(open(sys.argv[1]))["sessions"].values() if r.get("state") == "live" and r.get("name") == sys.argv[2]]
except Exception: rows = []
rows.sort(key=lambda r: r.get("created") or "")
print((rows[-1].get(sys.argv[3]) or "") if rows else "")
PY
}
hand sala-test-side-a "$SU1" "$HOME/work"; hand sala-test-side-b "$SU2" "$HOME/work"; hand sala-test-side-c "$SU3" "$HOME/work"; hand sala-test-side-d "$SU4" "$HOME/work"; hand sala-test-side-e "$SU5" "$HOME/work"
fake_up sala-test-side-a sala-test-side-b sala-test-side-c sala-test-side-d sala-test-side-e
for n in a b c d e; do "$SALA" adopt sala-test-side-$n >/dev/null 2>&1; done
sidemake sala-test-side-a projects/foo gamma-foo-main
sidemake sala-test-side-b projects/foo gamma-foo-main
sidemake sala-test-side-c "" gamma-foo-hand          # no project on the record, and its origin has none
sidemake sala-test-side-e projects/foo gamma-foo-main
sidemake sala-test-side-d "" gamma-foo-hand         # no project on the record: the origin's row gives it (below)
sessions_set gamma-foo-hand "project=projects/foo" "role=front"   # the origin agent's registry row names a project
[ -f "$(side_file sala-test-side-a)" ] && [ "$(rowfield sala-test-side-a side)" = 1 ] && ok "side records and registry rows in place" || bad "side setup: $(rowfield sala-test-side-a side)"
mode renamed; printf 'recorded\n' > "$HOME/client-mode-agent"
setname sala-test-side-a gamma-foo-promoted; setname sala-test-side-b gamma-foo-refused; setname sala-test-side-c gamma-foo-noproj; setname sala-test-side-d gamma-foo-viaorigin; setname sala-test-side-e gamma-foo-already

# (a) the plan names the project, the line and the side record; nothing is called or changed
n0=$(calls); MAP_BEFORE=$(slurp "$MAP")
out=$("$SALA" rename sala-test-side-a gamma-foo-promoted --dry-run 2>&1); rc=$?
echo "$out" | sed 's/^/    /' | cut -c1-260
[ "$rc" = 0 ] && has "$out" "rename: lists 'gamma-foo-promoted' on projects/foo (front, line: look into the foo hosting move) and ends the side record" \
    && has "$out" "role promoted" && has "$out" "write-up (sala side done" && ok "the plan: lists NEW on projects/foo (front, Rowan's first line as the mandate) and ends the side record" || bad "side plan: rc=$rc"
[ "$(calls)" = "$n0" ] && [ -f "$(side_file sala-test-side-a)" ] && untouched sala-test-side-a gamma-foo-promoted && ok "the dry run calls nothing and changes nothing" || bad "dry run changed something"

# (b) the real run: project-agent (label sala-web), the rename, the record gone
out=$("$SALA" rename sala-test-side-a gamma-foo-promoted 2>&1); rc=$?
echo "$out" | sed 's/^/    /' | cut -c1-260
[ "$rc" = 0 ] && has "$out" "✅ 'sala-test-side-a' is now 'gamma-foo-promoted'" && has "$out" "'gamma-foo-promoted' is listed on projects/foo as a front agent (role promoted" && has "$out" "no longer a side session" \
    && ok "renamed; the output says it is listed (pending) and no longer a side session" || bad "side rename: rc=$rc"
[ "$(calls)" = $((n0 + 1)) ] && [ "$(tail -1 "$CALLS" | tr '\037' ' ')" = "post project-agent projects/foo gamma-foo-promoted --role promoted --front --mandate look into the foo hosting move --sender sala-web" ] \
    && ok "one call: post project-agent projects/foo gamma-foo-promoted --role promoted --front --mandate <Rowan's first line> --sender sala-web" || bad "side call: $(tail -1 "$CALLS" | tr '\037' ' ')"
tmux has-session -t =gamma-foo-promoted 2>/dev/null && [ -n "$(row gamma-foo-promoted)" ] && [ -z "$(row sala-test-side-a)" ] && ok "tmux session and map row follow the name" || bad "after the side rename: $(slurp "$MAP")"
[ ! -e "$(side_file sala-test-side-a)" ] && [ ! -e "$(side_done_file sala-test-side-a)" ] && [ -f "$SALA_SIDE_DIR/retired/sala-test-side-a.side" ] && grep -q '^renamed_to=gamma-foo-promoted$' "$SALA_SIDE_DIR/retired/sala-test-side-a.side" \
    && ok "the side record is gone from side/ (kept in side/retired/, saying where it went), no marker left" || bad "side files: $(ls "$SALA_SIDE_DIR" "$SALA_SIDE_DIR/retired" 2>&1 | tr '\n' ' ')"
[ -z "$(rowfield gamma-foo-promoted side)" ] && [ -z "$(rowfield gamma-foo-promoted side_origin)" ] && [ -z "$(rowfield gamma-foo-promoted side_item)" ] && [ -z "$(rowfield gamma-foo-promoted side_at)" ] \
    && [ "$(rowfield gamma-foo-promoted project)" = projects/foo ] && [ "$(rowfield gamma-foo-promoted role)" = front ] \
    && ok "the registry row: side fields cleared, tagged projects/foo / front" || bad "row fields: side=$(rowfield gamma-foo-promoted side) project=$(rowfield gamma-foo-promoted project) role=$(rowfield gamma-foo-promoted role)"
out=$(agent_unlisted gamma-foo-promoted); rc=$?   # (the stub's listed.txt stands in for the project record's pending entry)
[ "$rc" = 1 ] && ok "afterwards the name counts as listed (agent_unlisted: no), as the project record's pending entry makes it" || bad "still unlisted: $out"

# (c) stackshot refuses (403, 400, unreachable): nothing renamed, the record and the row kept, the reason printed
for m in 403 400 409 unreachable; do
    printf '%s\n' "$m" > "$HOME/client-mode-agent"; n0=$(calls); MAP_BEFORE=$(slurp "$MAP")
    out=$("$SALA" rename sala-test-side-b gamma-foo-refused 2>&1); rc=$?
    [ "$rc" != 0 ] && has "$out" "rename refused, nothing renamed: stackshot's project-agent call failed (exit 1): stackshot: agent not listed [$([ "$m" = unreachable ] && echo 0 || echo "$m")]" && [ "$(calls)" = $((n0 + 1)) ] \
        && untouched sala-test-side-b gamma-foo-refused && [ -f "$(side_file sala-test-side-b)" ] && [ "$(rowfield sala-test-side-b side)" = 1 ] && [ -z "$(rowfield sala-test-side-b project)" ] \
        && ok "$m: refused with stackshot's reason, one call, tmux session, pane map, side record and row unchanged" || { echo "$out" | sed 's/^/    /' | cut -c1-260; bad "$m: rc=$rc calls=$(calls) (was $n0)"; }
done
printf 'recorded\n' > "$HOME/client-mode-agent"
n0=$(calls)
out=$(SALA_STACKSHOT_CLIENT="$HOME/nowhere.py" SALA_STACKSHOT_DIR= "$SALA" rename sala-test-side-b gamma-foo-refused 2>&1); rc=$?
[ "$rc" != 0 ] && has "$out" "no stackshot client.py on this box" && [ "$(calls)" = "$n0" ] && untouched sala-test-side-b gamma-foo-refused && [ -f "$(side_file sala-test-side-b)" ] \
    && ok "no client.py: refused, naming it, the side record kept" || bad "no client: rc=$rc $out"

# (d) no project on the record and none on its origin: refused in the plan, with the reason, before anything started
n0=$(calls); MAP_BEFORE=$(slurp "$MAP")
sessions_set gamma-foo-hand "project=" "role="
out=$("$SALA" rename sala-test-side-c gamma-foo-noproj --dry-run 2>&1); rc=$?
echo "$out" | sed 's/^/    /' | cut -c1-260
[ "$rc" != 0 ] && has "$out" "'sala-test-side-c' is a side session with no project on its record (nor has its origin 'gamma-foo-hand' one)" && [ "$(calls)" = "$n0" ] && [ -f "$(side_file sala-test-side-c)" ] && untouched sala-test-side-c gamma-foo-noproj \
    && ok "no project: refused in --dry-run (the plan) with the reason, no call, nothing changed" || bad "no project plan: rc=$rc"
out=$("$SALA" rename sala-test-side-c gamma-foo-noproj 2>&1); rc=$?
[ "$rc" != 0 ] && has "$out" "is a side session with no project on its record" && [ "$(calls)" = "$n0" ] && untouched sala-test-side-c gamma-foo-noproj && ok "the real run is refused the same way, before anything started" || bad "no project run: rc=$rc"

# (e) no project on the record, but the origin agent's registry row names one: that is the project
sessions_set gamma-foo-hand "project=projects/foo" "role=front"
out=$("$SALA" rename sala-test-side-d gamma-foo-viaorigin 2>&1); rc=$?
[ "$rc" = 0 ] && has "$(tail -1 "$CALLS" | tr '\037' ' ')" "post project-agent projects/foo gamma-foo-viaorigin --role viaorigin --front" && [ ! -e "$(side_file sala-test-side-d)" ] \
    && ok "the origin's project is used when the record has none" || { echo "$out" | sed 's/^/    /' | cut -c1-260; bad "origin fallback: rc=$rc $(tail -1 "$CALLS" | tr '\037' ' ')"; }

# (f) a side session renamed to another side name, or followed by --sync, never calls project-agent; --sync leaves the record where it is (unchanged behaviour)
n0=$(calls)
out=$(SALA_RENAME_SYNC=1 "$SALA" rename sala-test-side-b gamma-foo-refused 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(calls)" = "$n0" ] && tmux has-session -t =gamma-foo-refused 2>/dev/null && [ -f "$(side_file sala-test-side-b)" ] && ok "--sync (a hand rename): followed, no call, the record untouched" || bad "sync of a side session: rc=$rc $out"

# (g) NEW already listed on its project (a page line, or a pending entry): no call; the side record still ends, so it is not left behind under the old name
printf 'projects/foo\tgamma-foo-already\tlisted before\n' >> "$HOME/listed.txt"; n0=$(calls)
out=$("$SALA" rename sala-test-side-e gamma-foo-already 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(calls)" = "$n0" ] && tmux has-session -t =gamma-foo-already 2>/dev/null && [ ! -e "$(side_file sala-test-side-e)" ] && [ -f "$SALA_SIDE_DIR/retired/sala-test-side-e.side" ] \
    && [ -z "$(rowfield gamma-foo-already side)" ] && [ -z "$(rowfield gamma-foo-already project)" ] \
    && ok "NEW already listed: renamed with no project-agent call, the side record ended (the row not tagged: no listing was made)" || { echo "$out" | sed 's/^/    /' | cut -c1-260; bad "listed NEW: rc=$rc calls=$(calls)"; }

echo "== the side record of a spawn in flight: the side-or-in-place decision waits for the .side file (spawn --side writes it late), on the same budget"
LU1=aaaaaaaa-0000-4000-8000-000000000031 LU2=aaaaaaaa-0000-4000-8000-000000000032 LU3=aaaaaaaa-0000-4000-8000-000000000033 LU4=aaaaaaaa-0000-4000-8000-000000000034
LU5=aaaaaaaa-0000-4000-8000-000000000035 LU6=aaaaaaaa-0000-4000-8000-000000000036
for n in l1:sala-test-side-l1:$LU1 l2:sala-test-side-l2:$LU2 l3:sala-test-nw1:$LU3 l4:sala-test-side-l4:$LU4 l5:sala-test-side-l5:$LU5 l6:sala-test-nw2:$LU6; do
    IFS=: read -r k s u <<<"$n"; hand "$s" "$u" "$HOME/work"; fake_up "$s"; "$SALA" adopt "$s" >/dev/null 2>&1; setname "$s" "gamma-foo-$k"
done
# (a) a young -side- session, its .side file lands 3 s late: the plan waits for it and takes the side path (lists NEW, ends the record), no in-place call
n0=$(calls)
rename_late "… waiting for the spawn of 'sala-test-side-l1' to land its side record" 'sidemake sala-test-side-l1 projects/foo gamma-foo-main' "$SALA" rename sala-test-side-l1 gamma-foo-l1 --dry-run
echo "$out" | sed 's/^/    /' | cut -c1-240
[ "$rc" = 0 ] && has "$out" "… waiting for the spawn of 'sala-test-side-l1' to land its side record (up to 60 s)" && [ "$el" -ge 2 ] && [ "$el" -lt "$(scale 15)" ] \
    && has "$out" "rename: lists 'gamma-foo-l1' on projects/foo (front, line: look into the foo hosting move) and ends the side record" && has "$out" "the side record of 'sala-test-side-l1' ends" \
    && ! has "$out" "in place" && [ "$(calls)" = "$n0" ] && ok "side record landed after ~3 s: waited (${el} s), the plan lists NEW and ends the side record, no in-place call planned" || bad "side record lands late: rc=$rc after ${el} s"
# (b) the same with no side file ever: today's behaviour after SALA_RENAME_MAP_WAIT (2 s): the in-place plan; one wait line only (the budget is spent once)
SECONDS=0; out=$(SALA_RENAME_MAP_WAIT=2 "$SALA" rename sala-test-side-l2 gamma-foo-l2 --dry-run 2>&1); rc=$?; el=$SECONDS
echo "$out" | sed 's/^/    /' | cut -c1-240
[ "$rc" = 0 ] && has "$out" "… waiting for the spawn of 'sala-test-side-l2' to land its side record (up to 2 s)" && [ "$el" -ge 2 ] && [ "$el" -lt "$(scale 9)" ] \
    && has "$out" "in place" && ! has "$out" "lists 'gamma-foo-l2'" && [ "$(echo "$out" | grep -c "waiting for the spawn")" = 1 ] \
    && ok "no side record: waited (${el} s), then the in-place plan as before, the wait spent once" || bad "no side record: rc=$rc after ${el} s"
# (c) a young session that is not a side one: no side-record wait, the in-place plan at once
SECONDS=0; out=$(SALA_RENAME_MAP_WAIT=30 "$SALA" rename sala-test-nw1 gamma-foo-l3 --dry-run 2>&1); rc=$?; el=$SECONDS
[ "$rc" = 0 ] && ! has "$out" "waiting for the spawn" && [ "$el" -lt "$(scale 6)" ] && has "$out" "in place" && ok "young non-side session: no extra wait line (${el} s), the in-place plan" || bad "young non-side: rc=$rc after ${el} s: $out"
# (d) --sync never waits, a young -side- session without a record included
SECONDS=0; out=$(SALA_RENAME_SYNC=1 SALA_RENAME_MAP_WAIT=30 "$SALA" rename sala-test-side-l4 gamma-foo-l4 2>&1); rc=$?; el=$SECONDS
[ "$rc" = 0 ] && ! has "$out" "waiting for the spawn" && [ "$el" -lt "$(scale 6)" ] && tmux has-session -t =gamma-foo-l4 2>/dev/null && ok "--sync: no wait on a young -side- session without a record (${el} s), the hand rename followed" || bad "sync, side-named: rc=$rc after ${el} s: $out"
# (e) the spawn operation answers exactly: an in-flight spawn op for a -side- name WITHOUT --side is no side spawn (no side-record wait)...
mkdir -p "$SALA_STATE_DIR/ops"; OPF="$SALA_STATE_DIR/ops/2-1.op"
printf 'id=2-1\nverb=spawn\narg=sala-test-side-l5\narg=--project\narg=projects/foo\narg=--role\narg=front\nstate=running\n' > "$OPF"
SECONDS=0; out=$(SALA_RENAME_MAP_WAIT=30 "$SALA" rename sala-test-side-l5 gamma-foo-l5 --dry-run 2>&1); rc=$?; el=$SECONDS
[ "$rc" = 0 ] && ! has "$out" "waiting for the spawn" && [ "$el" -lt "$(scale 6)" ] && has "$out" "in place" && ok "a spawn op without --side: not waited for, whatever the name says" || bad "op without --side: rc=$rc after ${el} s: $out"
# (f) ...and one with --side is, whatever the name (the side record lands 3 s late here too)
printf 'id=2-1\nverb=spawn\narg=sala-test-nw2\narg=--side\narg=--fork-of\narg=gamma-foo-main\nstate=running\n' > "$OPF"
rename_late "… waiting for the spawn of 'sala-test-nw2' to land its side record" 'sidemake sala-test-nw2 projects/foo gamma-foo-main' env SALA_RENAME_MAP_WAIT=30 "$SALA" rename sala-test-nw2 gamma-foo-l6 --dry-run
[ "$rc" = 0 ] && has "$out" "… waiting for the spawn of 'sala-test-nw2' to land its side record" && [ "$el" -ge 2 ] && has "$out" "rename: lists 'gamma-foo-l6' on projects/foo" && ! has "$out" "in place" \
    && ok "a spawn op with --side: waited for the record (${el} s), then the side plan" || { echo "$out" | sed 's/^/    /' | cut -c1-240; bad "op with --side: rc=$rc after ${el} s"; }
rm -f "$OPF"

[ "$fail" = 0 ] && echo "rename: all passed" || { echo "rename: FAILED"; exit 1; }
