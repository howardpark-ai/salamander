#!/usr/bin/env bash
# The side sessions (quick side conversations; lib/spawn.sh A SIDE SESSION, lib/side.sh, lib/retire.sh, lib/common.sh
# THE SIDE SESSIONS, docs/side-sessions.md). A side session is a short-lived session started in one step: a FORK of a running agent's
# conversation (spawn --side --fork-of AGENT) or a FRESH session about a board item (spawn --side --project KEY --item board#N), on no page's
# agents map, retired only on the owner's word and only after its write-up (`sala side done`). Checked here, with stubs for everything outside
# the box: the argument matrix refused before anything is made; the generated names (<prefix>-side-<word><nn>, the prefix cut to fit, the
# project's -main from stackshot's record, the agent forked from); the dry run making nothing; the real start of each kind (the session up,
# the mandate file written with the item, its link, the agents and the end rules, the record under side/, the registry row's side fields,
# the fork's conversation and directory); `side done` (every check run and every failure said: the item changed since the start, by the
# agents' items or by --item-updated; the project page's timeline line from the session, dated from the start, from the brain mirror or
# the weaker page-ts; the summary sent once, with [for Rowan] to a -main (another agent plain, marked once on a front-agent refusal; projects/<slug> targets), never again; a failing send leaving no marker); the retire gate
# (refused in the dry run and for real until the marker, --force the one bypass, a plain session untouched, the record moved after the
# retire). stackshot's client is a set of stubs (SALA_SIDE_ITEMS_CMD, SALA_SIDE_PAGE_TS_CMD, SALA_SIDE_MSG_CMD), pages.py a stub
# (SALA_AGENT_CHECK_SCRIPT), the project record a file; the compiled fake claude, a private tmux socket and an isolated HOME. No real
# session, page, board item or message is touched.
# Usage: bash tests/side.sh   (exit 0 = pass; ~60 s)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_MASTER SALA_SET SALA_SET_SELF SALA_RECYCLE SALA_RETRY_WORKER SALA_LOCK_WHO SALA_LOCK_WAIT SALA_RELAUNCH_KIND \
      SALA_FLEET_HOSTS SALA_CGROUP_FILE SALA_OP_QUEUE SALA_OP_REBOOT SALA_OP_STUCK SALA_REBOOT_HOOKS SALA_NO_RELAUNCH SALA_SPAWN_REGISTER \
      SALA_AGENT_CHECK SALA_AGENT_CHECK_SCRIPT SALA_SPAWN_ASK_CMD SALA_OP_FROM SALA_OP_WORDS SALA_OP_ID SALA_OP_PLAN SALA_SESSION_ID \
      SALA_SIDE_ITEMS_CMD SALA_SIDE_PAGE_TS_CMD SALA_SIDE_MSG_CMD SALA_BRAIN_DIR SALA_PROJECT_RECORD
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"   # short timings, ok/bad/waitfor, fake_up, tmux_socket_rm, as_op_unit; the lane variables unset
# the made-up fleet these checks were written against: three scopes, so a page the project record does not know is named <scope>-<slug>
# (tests/neutral-defaults.sh covers none set)
export SALA_SCOPES="example beta gamma" SALA_DEFAULT_SCOPE=gamma
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC
export SALA_STACKSHOT_WEB=https://board.example.com   # a side session's mandate links its item under this address (empty by default; tests/neutral-defaults.sh checks the empty case)
as_op_unit   # no master: the retires this suite runs itself stand for the queue's runner (tests/lib.sh, 5)
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect" "$HOME/pages/projects" "$HOME/pages/infra" "$HOME/work" "$HOME/brain/projects"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
mkdir -p "$HOME/.local/share/claude/versions"; cc -o "$HOME/.local/share/claude/versions/9.9.9" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (an EXIT trap may not exist yet here)
ln -s "$HOME/.local/share/claude/versions/9.9.9" "$HOME/.local/bin/claude"
# the stub pages.py (stackshot's; SALA_AGENT_CHECK_SCRIPT): `resolve <key>` answers from $HOME/pages/<key>.md; agent-listed says "not listed" (a side session must not need it)
cat > "$HOME/fake-pages.py" <<'PY'
import os, sys
home = os.environ["HOME"]; cmd = sys.argv[1]; arg = sys.argv[2] if len(sys.argv) > 2 else ""
open(home + "/pages-calls.txt", "a").write(" ".join(sys.argv[1:]) + "\n")
if cmd == "resolve":
    ex = os.path.exists(f"{home}/pages/{arg}.md"); print(arg, ex); sys.exit(0 if ex else 1)
if cmd == "agent-listed":
    print(f"not listed: {arg} is not under `agents:` on projects/foo (the page whose `display-name:` line is gamma-foo). The line `{arg}: <mandate>` has to be added there first."); sys.exit(3)
sys.exit(1)
PY
# stackshot's client, stubbed. items <agent>: $HOME/items-<agent>.json when it exists, else {"items": []} · page-ts <key>: $HOME/page-ts.json
# or exit 1 · message <to> - --sender <name>: the arguments and stdin to $HOME/msgs.txt (a record ends with %%), $HOME/msg-fail makes it exit 7
cat > "$HOME/fake-items" <<'EOF'
#!/bin/bash
echo "$1" >> "$HOME/items-calls.txt"
if [ -f "$HOME/items-$1.json" ]; then cat "$HOME/items-$1.json"; else echo '{"items": []}'; fi
EOF
cat > "$HOME/fake-pagets" <<'EOF'
#!/bin/bash
echo "$1" >> "$HOME/pagets-calls.txt"
[ -f "$HOME/page-ts.json" ] && cat "$HOME/page-ts.json" || exit 1
EOF
cat > "$HOME/fake-msg" <<'EOF'
#!/bin/bash
IN=$(cat); FIRST=$(head -1 <<< "$IN")
printf 'TRY %s | first line: %s\n' "$*" "$FIRST" >> "$HOME/tries.txt"
[ -e "$HOME/msg-fail" ] && { echo "boom" >&2; exit 7; }
[ -e "$HOME/msg-refuse-other" ] && { echo "400: the project page is locked" >&2; exit 1; }
# stackshot's refusal of a message to a front agent without [for Rowan] on line 1 (the real text)
[ -e "$HOME/msg-refuse-front" ] && [ "$FIRST" != "[for Rowan]" ] && { echo "400: $1 is a front agent of foo, a session Rowan talks to, and it takes a message only when the message's first line carries [for Rowan]" >&2; exit 1; }
{ printf 'ARGS %s\n' "$*"; printf '%s\n' "$IN"; echo "%%"; } >> "$HOME/msgs.txt"
EOF
chmod +x "$HOME/fake-items" "$HOME/fake-pagets" "$HOME/fake-msg"
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.log"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="cat >> $POSTS"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off
export SALA_LIMIT_ALERT=off SALA_LIMIT_RESUME=off SALA_STUCK_POST=off
export SALA_AGENT_CHECK_SCRIPT="$HOME/fake-pages.py" SALA_SPAWN_ASK_CMD="$HOME/fake-msg" SALA_PROJECT_RECORD="$HOME/projects.json"
export SALA_SIDE_ITEMS_CMD="$HOME/fake-items" SALA_SIDE_PAGE_TS_CMD="$HOME/fake-pagets" SALA_SIDE_MSG_CMD="$HOME/fake-msg" SALA_BRAIN_DIR="$HOME/brain"
SALA="$ROOT/bin/salamander"; SOCK="sala-side-$$"; T="tmux -L $SOCK -f /dev/null"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"
cleanup() {
    local p; $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    for p in $(pgrep -x claude); do [ "$HOME/.local/share/claude/versions/9.9.9" -ef "/proc/$p/exe" ] && kill -9 "$p" 2>/dev/null; done
    rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux
. "$ROOT/lib/common.sh"
SIDE="$SALA_STATE_DIR/side"; MANDATES="$SALA_STATE_DIR/mandates"; TYPED="$HOME/typed.log"; REG="$SALA_SESSIONS_FILE"
hasnt() { ! grep -qF -- "$2" <<< "$1"; }
run() { OUT=$("$SALA" spawn "$@" 2>&1); RC=$?; }
sd() { OUT=$("$SALA" side done "$@" 2>&1 </dev/null); RC=$?; }
sessions() { tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -v '^keep-alive$' | paste -sd' ' -; }
nmsgs() { grep -c '^%%$' "$HOME/msgs.txt" 2>/dev/null || echo 0; }
rowq() {  # <name> <field> → a field of the newest registry row of that name ("<none>" when no row; "None" for a null)
    python3 - "$REG" "$1" "$2" <<'PY'
import json, sys
f, name, what = sys.argv[1:4]
try: rows = [r for r in json.load(open(f))["sessions"].values() if r["name"] == name]
except Exception: rows = []
rows.sort(key=lambda r: r["created"])
print(rows[-1].get(what) if rows else "<none>")
PY
}
sval() { awk -F= -v k="$2" '$1==k {print substr($0, length(k)+2)}' "$SIDE/$1.side" 2>/dev/null | tail -1; }   # <name> <key> → a field of the side record
TODAY=$(TZ=Etc/UTC date +%Y-%m-%d)
cat > "$HOME/brain/projects/foo.md" <<'EOF'
# Foo

## Current state
Fine.

## Timeline
- **2020-01-01** | gamma-foo-side-old01 — a line from long ago
EOF
touch "$HOME/pages/projects/foo.md"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
cat > "$HOME/projects.json" <<EOF
{"schema": 1, "generated": "$NOW", "projects": {"prj_example": {"id": "prj_example", "key": "projects/foo", "keeper": "k", "agents": {"acme-main": {"front": true, "role": "front", "mandate_line": "Rowan's contact"}}}}, "by_key": {"projects/foo": "prj_example"}}
EOF
tmux new-session -d -s keep-alive   # the server the spawns land on, with the fake's environment
tmux set-environment -g FAKE_LOG "$FAKE_LOG"; tmux set-environment -g FAKE_TYPED_LOG "$TYPED"
fakeenv() { tmux set-environment -g FAKE_SESSION_ID "$1"; tmux set-environment -g FAKE_NAME "$2"; }

echo "== the argument matrix: refused before anything is made (no session, no page asked for the agents map)"
run x --side; [ "$RC" = 1 ] && has "$OUT" "--side needs --fork-of AGENT" && ok "--side alone" || bad "side alone: rc=$RC — $OUT"
run gamma-foo-side-wren01 --side --project projects/foo --role front; [ "$RC" = 1 ] && has "$OUT" "--side takes no --role" && ok "--side with --role" || bad "side role: rc=$RC — $OUT"
run gamma-foo-side-wren01 --side --project projects/foo; [ "$RC" = 1 ] && has "$OUT" "needs --item board#N" && ok "a start about a project without --item" || bad "no item: rc=$RC — $OUT"
run gamma-foo-side-wren01 --side --project projects/foo --item foo; [ "$RC" = 1 ] && has "$OUT" "board item id as shown" && ok "--item that is not board#N" || bad "item shape: rc=$RC — $OUT"
run gamma-foo-side-wren01 --side --project projects/foo --item board#9001 --agents "Bad Name"; [ "$RC" = 1 ] && has "$OUT" "--agents takes agent names" && ok "--agents with a bad name" || bad "agents shape: rc=$RC — $OUT"
run gamma-foo-side-wren01 --side --fork-of gamma-foo-main --project projects/foo; [ "$RC" = 1 ] && has "$OUT" "--fork-of takes no --project" && ok "--fork-of with --project" || bad "fork+project: rc=$RC — $OUT"
run gamma-foo-side-wren01 --side --fork-of gamma-foo-main --agents a; [ "$RC" = 1 ] && has "$OUT" "--agents is for a start about an item" && ok "--fork-of with --agents" || bad "fork+agents: rc=$RC — $OUT"
run gamma-foo-side-wren01 --side --fork-of gamma-foo-main --fork "$(uuid 1)"; [ "$RC" = 1 ] && has "$OUT" "--side forks with --fork-of AGENT" && ok "--side with --fork UUID" || bad "side+fork: rc=$RC — $OUT"
run gamma-foo-side-wren01 --side --project projects/foo --item board#9001 --master; [ "$RC" = 1 ] && has "$OUT" "cannot go together" && ok "--side with --master" || bad "side+master: rc=$RC — $OUT"
run gamma-foo-wren01 --side --project projects/foo --item board#9001 --dry-run; [ "$RC" = 1 ] && has "$OUT" "contains -side-" && ok "a name without -side-" || bad "name: rc=$RC — $OUT"
run gamma-foo-side-wren01 --fork-of gamma-foo-main; [ "$RC" = 1 ] && has "$OUT" "go with --side" && ok "--fork-of without --side" || bad "fork-of alone: rc=$RC — $OUT"
run gamma-foo-side-wren01 --item board#9001; [ "$RC" = 1 ] && has "$OUT" "go with --side" && ok "--item without --side" || bad "item alone: rc=$RC — $OUT"
run gamma-foo-side-wren01 --side --fork-of gamma-foo-main --dry-run; [ "$RC" = 1 ] && has "$OUT" "no live session 'gamma-foo-main' to fork" && ok "a fork of an agent that is not running" || bad "no live agent: rc=$RC — $OUT"
[ -z "$(sessions)" ] && ok "none of them made a session" || bad "sessions: $(sessions)"

echo "== names: <prefix>-side-<word><nn>, the project's -main from stackshot's record, the prefix cut to fit"
run --suggest-name --side --project projects/foo
[ "$RC" = 0 ] && grep -qE '^acme-side-[a-z]+[0-9]{2}$' <<< "$OUT" && ok "the record's -main agent (acme-main) gives the prefix: $OUT" || bad "suggest (record): rc=$RC — $OUT"
SALA_PROJECT_RECORD=/nonexistent run --suggest-name --side --project projects/foo
[ "$RC" = 0 ] && grep -qE '^gamma-foo-side-[a-z]+[0-9]{2}$' <<< "$OUT" && ok "no record: the conventional prefix (gamma-foo): $OUT" || bad "suggest (no record): rc=$RC — $OUT"
LONG=$(printf '%*s' 60 '' | tr ' ' k)
SALA_PROJECT_RECORD=/nonexistent run --suggest-name --side --project "projects/$LONG"
[ "$RC" = 0 ] && grep -qE -- '-side-[a-z]+[0-9]{2}$' <<< "$OUT" && [ "${#OUT}" -le 48 ] && agent_name_ok "$OUT" && ok "a long project slug: ${#OUT} characters (SALA_AGENT_NAME_MAX), still an agent name" || bad "suggest (long): rc=$RC (${#OUT}) — $OUT"
run --suggest-name --side --fork-of gamma-foo-main-side-old01; [ "$RC" = 0 ] && grep -qE '^gamma-foo-main-side-[a-z]+[0-9]{2}$' <<< "$OUT" && ok "a fork name is made from the agent's name (a side session's own -side- part is cut): $OUT" || bad "suggest fork (name only): rc=$RC — $OUT"

echo "== the dry run of a start about an item: makes, records and calls nothing; the agents map is not asked"
: > "$HOME/pages-calls.txt"
run gamma-foo-side-mica07 --side --project projects/foo --item board#12 --agents acme-main,example-x-builder --dry-run
[ "$RC" = 0 ] && has "$OUT" "[dry-run] would spawn 'gamma-foo-side-mica07' as a side session (a fresh start about board#12 of projects/foo, item board#12; on no agents map; its write-up summary goes to acme-main)" \
    && has "$OUT" "mandate: written to $MANDATES/side-gamma-foo-side-mica07.md" && has "$OUT" "naming the agents acme-main,example-x-builder" && ok "the plan names the kind, the item, the summary's receiver, the mandate file and the agents" || bad "dry run: rc=$RC — $OUT"
[ ! -e "$MANDATES/side-gamma-foo-side-mica07.md" ] && [ ! -e "$SIDE/gamma-foo-side-mica07.side" ] && [ -z "$(sessions)" ] && ! grep -q '^agent-listed' "$HOME/pages-calls.txt" && ok "nothing written, no session, agent-listed never asked" || bad "dry run left: $(ls "$MANDATES" "$SIDE" 2>&1) / $(sessions) / $(<"$HOME/pages-calls.txt")"
run gamma-foo-side-mica07 --side --project projects/nope --item board#12 --dry-run
[ "$RC" = 4 ] && grep -qx 'NO-PAGE: projects/nope' <<< "$OUT" && ok "a project with no page: exit 4, NO-PAGE:" || bad "no page: rc=$RC — $OUT"

for id in s9 board-tmp-box#3 a5; do   # the forms stackshot shows (its Discuss link carries any of them)
    run gamma-foo-side-mica07 --side --project projects/foo --item "$id" --dry-run
    [ "$RC" = 0 ] && has "$OUT" "item $id;" && ok "--item $id: accepted" || bad "item $id: rc=$RC — $OUT"
done
enq() { OUT=$("$SALA" op "$@" 2>&1); RC=$?; }
enq --plan spawn gamma-foo-side-mica07 --side --project projects/foo --item board-tmp-box#3
[ "$RC" = 0 ] && has "$OUT" "plan only: nothing queued" && ok "sala op spawn --side takes board-tmp-box#3 as well" || bad "op item form: rc=$RC — $OUT"
run gamma-foo-side-mica07 --side --project projects/foo --item "board#"; [ "$RC" = 1 ] && ok "board# with no number: refused" || bad "empty number: rc=$RC — $OUT"

echo "== the real start of a fresh session about an item"
fakeenv "$(uuid 21)" gamma-foo-side-mica07
run gamma-foo-side-mica07 --side --project projects/foo --item board#12 --agents acme-main,example-x-builder --no-confirm --mandate "Focus on the deploy question only." --cwd "$HOME/work"
[ "$RC" = 0 ] && has "$OUT" "✅ spawned 'gamma-foo-side-mica07'" && has "$OUT" "side    : discuss, board#12 (projects/foo)" && ok "spawned (exit 0), the side line printed" || bad "spawn: rc=$RC — $OUT"
[ "$(sessions)" = gamma-foo-side-mica07 ] && fake_up gamma-foo-side-mica07 && ok "the session is up with its claude" || bad "session: $(sessions)"
M="$MANDATES/side-gamma-foo-side-mica07.md"
[ -s "$M" ] && has "$(<"$M")" "https://board.example.com/items/12" && has "$(<"$M")" "board#12" && has "$(<"$M")" 'project page `projects/foo`' \
    && has "$(<"$M")" '`acme-main`, `example-x-builder`' && has "$(<"$M")" "sala sessions transcript" && has "$(<"$M")" "ONLY the transcript excerpts you need" \
    && has "$(<"$M")" "sala side done --item board#12" && has "$(<"$M")" "retire only when Rowan tells you" && has "$(<"$M")" "Focus on the deploy question only." && ok "the mandate: the item and its link, the page, the agents, the transcript rule, side done, retire-only-on-the-owner's-word, the owner's own instruction appended" || bad "mandate: $(cat "$M" 2>&1 | head -30)"
hasnt "$(<"$M")" "a fork of" && ok "the mandate of a fresh session does not claim to be a fork" || bad "mandate says fork"
waitfor "grep -q 'side-gamma-foo-side-mica07.md' '$TYPED'" 20 && ok "the orientation line typed names the mandate file" || bad "typed: $(cat "$TYPED" 2>/dev/null | tail -3)"
[ "$(sval gamma-foo-side-mica07 kind)" = discuss ] && [ "$(sval gamma-foo-side-mica07 item)" = board#12 ] && [ "$(sval gamma-foo-side-mica07 project)" = projects/foo ] \
    && [ "$(sval gamma-foo-side-mica07 summary_to)" = acme-main ] && [ "$(sval gamma-foo-side-mica07 agents)" = acme-main,example-x-builder ] && [ -n "$(sval gamma-foo-side-mica07 started)" ] \
    && ok "the record: kind, item, project, summary_to, agents, started" || bad "record: $(cat "$SIDE/gamma-foo-side-mica07.side" 2>&1)"
[ "$(rowq gamma-foo-side-mica07 side)" = 1 ] && [ "$(rowq gamma-foo-side-mica07 side_item)" = board#12 ] && [ "$(rowq gamma-foo-side-mica07 project)" = None ] && ok "the registry row: side=1, side_item, and no project/role (it is on no map)" || bad "row: side=$(rowq gamma-foo-side-mica07 side) item=$(rowq gamma-foo-side-mica07 side_item) project=$(rowq gamma-foo-side-mica07 project)"
OUT=$("$SALA" sessions 2>&1); [ "$(awk '$2=="gamma-foo-side-mica07" {print $7}' <<< "$OUT")" = side ] && ok "sessions list shows it with the side tag" || bad "list: $OUT"
run gamma-foo-side-mica07 --side --project projects/foo --item board#12 --dry-run
[ "$RC" = 1 ] && has "$OUT" "already exists" && ok "the same name again: refused" || bad "same name: rc=$RC — $OUT"

echo "== the real fork of a running agent: its conversation, its directory, its name"
mkdir -p "$HOME/agentcwd"
UO=$(uuid 31); echo '{"type":"user"}' > "$HOME/.claude/projects/x/$UO.jsonl"
tmux new-session -d -s gamma-foo-lead -c "$HOME/agentcwd" -e FAKE_SESSION_ID="$UO" -e FAKE_NAME=gamma-foo-lead -e FAKE_LOG="$FAKE_LOG"; tmux send-keys -t gamma-foo-lead 'claude' Enter
fake_up gamma-foo-lead || bad "the fake under gamma-foo-lead did not come up"
run --suggest-name --side --fork-of gamma-foo-lead
[ "$RC" = 0 ] && grep -qE '^gamma-foo-lead-side-[a-z]+[0-9]{2}$' <<< "$OUT" && ok "the fork's name: <agent>-side-<word><nn> ($OUT)" || bad "suggest fork: rc=$RC — $OUT"
run --side --fork-of gamma-foo-lead --dry-run
[ "$RC" = 0 ] && has "$OUT" "a fork of gamma-foo-lead" && has "$OUT" "forked from $UO" && has "$OUT" "cwd $HOME/agentcwd" && has "$OUT" "its write-up summary goes to gamma-foo-lead" && ok "dry run: the agent's conversation, its directory (the CLI finds a conversation by it), the summary to the agent" || bad "fork dry: rc=$RC — $OUT"
run --side --fork-of gamma-foo-lead --cwd "$HOME/work" --dry-run
[ "$RC" = 0 ] && has "$OUT" "cwd $HOME/work" && ok "--cwd still wins over the agent's directory" || bad "fork cwd: rc=$RC — $OUT"
FN=gamma-foo-lead-side-onyx42
fakeenv "$UO" "$FN"
run "$FN" --side --fork-of gamma-foo-lead --item board#9009 --no-confirm
[ "$RC" = 0 ] && has "$OUT" "✅ spawned '$FN'" && has "$OUT" "side    : fork of gamma-foo-lead, board#9009" && ok "forked (exit 0)" || bad "fork spawn: rc=$RC — $OUT"
fake_up "$FN" && waitfor "[ \"\$(grep -c '^start $UO ' '$FAKE_LOG')\" -ge 2 ]" 20 && ok "a second claude started on the agent's conversation (--resume --fork-session)" || bad "fork starts: $(grep "$UO" "$FAKE_LOG")"
[ "$(sval "$FN" kind)" = fork ] && [ "$(sval "$FN" origin)" = gamma-foo-lead ] && [ "$(sval "$FN" origin_uuid)" = "$UO" ] && [ "$(sval "$FN" summary_to)" = gamma-foo-lead ] && [ "$(sval "$FN" item)" = board#9009 ] && ok "the record: kind fork, origin, origin_uuid, summary_to the agent, the item" || bad "fork record: $(cat "$SIDE/$FN.side" 2>&1)"
F="$MANDATES/side-$FN.md"
has "$(<"$F")" 'a fork of the conversation of `gamma-foo-lead`' && has "$(<"$F")" 'sala sessions transcript gamma-foo-lead' && ok "the fork's mandate says it is a fork and where to find the agent's transcripts" || bad "fork mandate: $(head -12 "$F")"
[ "$(rowq "$FN" side_origin)" = gamma-foo-lead ] && ok "the registry row carries side_origin" || bad "row origin: $(rowq "$FN" side_origin)"
tmux kill-session -t =gamma-foo-lead 2>/dev/null

echo "== side done: every check run, every failure said, nothing sent until all hold"
S=gamma-foo-side-mica07
sd --name "$S"
[ "$RC" = 1 ] && has "$OUT" "✗ item:" && has "$OUT" "✗ page:" && has "$OUT" "✗ summary:" && has "$OUT" "no marker written" && ok "nothing done: all three marked, exit 1" || bad "nothing: rc=$RC — $OUT"
[ ! -e "$SIDE/$S.done" ] && [ "$(nmsgs)" = 0 ] && ok "no marker, no message" || bad "marker/messages: $(ls "$SIDE") $(nmsgs)"
sd --name "$S" --summary "decided: ship it"
[ "$RC" = 1 ] && has "$OUT" "✓ summary:" && has "$OUT" "✗ item:" && [ "$(nmsgs)" = 0 ] && ok "a summary given alone: still refused, still not sent (it goes out only when the rest holds)" || bad "summary alone: rc=$RC msgs=$(nmsgs) — $OUT"
# the item changed: acme-main lists board#12 updated after the start
STARTED=$(sval "$S" started)
echo "{\"items\": [{\"shown\": \"board#9007\", \"updated\": $((STARTED + 50))}, {\"shown\": \"board#12\", \"updated\": $((STARTED - 100))}]}" > "$HOME/items-acme-main.json"
sd --name "$S" --summary "decided: ship it"
[ "$RC" = 1 ] && has "$OUT" "✗ item: board#12 last changed" && has "$OUT" "not after the session started" && ok "the item listed but not changed since the start: refused" || bad "item stale: rc=$RC — $OUT"
echo "{\"items\": [{\"shown\": \"board#12\", \"updated\": $((STARTED + 50))}]}" > "$HOME/items-acme-main.json"
sd --name "$S" --summary "decided: ship it"
[ "$RC" = 1 ] && has "$OUT" "✓ item: board#12 changed" && has "$OUT" "✗ page:" && has "$OUT" "no timeline line from $S dated $TODAY or later" && ok "the item changed (read from the receiver's items), the page still without the session's line" || bad "item ok: rc=$RC — $OUT"
# a timeline line from another source, one dated before the start, one naming the session only in its text: none counts
printf -- '- **%s** | someone-else — spoke about %s\n- **2020-01-02** | %s — too old\n' "$TODAY" "$S" "$S" >> "$HOME/brain/projects/foo.md"
sd --name "$S" --summary "decided: ship it"
[ "$RC" = 1 ] && has "$OUT" "✗ page:" && ok "lines of another source, an old date and a mention in the text do not count" || bad "page imposters: rc=$RC — $OUT"
printf -- '- **%s** | %s — deploy question settled\n' "$TODAY" "$S" >> "$HOME/brain/projects/foo.md"
sd --name "$S" --summary "decided: ship it" --dry-run
[ "$RC" = 0 ] && has "$OUT" "✓ page: a timeline line of $TODAY" && has "$OUT" "dry run: nothing sent, no marker written" && [ "$(nmsgs)" = 0 ] && [ ! -e "$SIDE/$S.done" ] && ok "all hold, --dry-run: exit 0, nothing sent, no marker" || bad "dry ok: rc=$RC msgs=$(nmsgs) — $OUT"
echo "the long summary, line two" > "$HOME/side331-summary.txt"
sd --name "$S" --summary "$HOME/side331-summary.txt"
[ "$RC" = 0 ] && has "$OUT" "the summary was sent to acme-main" && has "$OUT" "the write-up marker is written" && [ -s "$SIDE/$S.done" ] && [ "$(nmsgs)" = 1 ] && ok "all hold: the summary sent (from a file), the marker written" || bad "done: rc=$RC msgs=$(nmsgs) — $OUT"
MSG=$(<"$HOME/msgs.txt")
[ "$(sed -n 1p <<< "$MSG")" = "ARGS acme-main - --sender $S" ] && [ "$(sed -n 2p <<< "$MSG")" = "[for Rowan]" ] && has "$MSG" "[side done] $S" && has "$MSG" "board#12" && has "$MSG" "the long summary, line two" \
    && ok "the message: to the project's -main, sender the session, [for Rowan] on line 1, the summary inside" || bad "message: $MSG"
sd --name "$S"
[ "$RC" = 0 ] && has "$OUT" "the write-up marker is there already" && [ "$(nmsgs)" = 1 ] && ok "a repeat: the marker is there, nothing sent again" || bad "repeat: rc=$RC msgs=$(nmsgs) — $OUT"

echo "== side done: --item-updated, a failing send, the page-ts fallback, --summary-to, a fork without an item"
# a second session, started by hand through the record (the spawn is checked above): the item is on nobody's list
mkrec() {  # <name> <kind> <origin> <project> <item> <summary_to> [started]
    mkdir -p "$SIDE"; rm -f "$SIDE/$1.done"
    printf 'name=%s\nkind=%s\norigin=%s\nproject=%s\nitem=%s\nagents=\nsummary_to=%s\nstarted=%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "${7:-$(date +%s)}" > "$SIDE/$1.side"
}
S2=gamma-foo-side-rowan11; mkrec "$S2" discuss "" projects/foo board#44 acme-main "$(( $(date +%s) - 120 ))"
printf -- '- **%s** | %s — settled\n' "$TODAY" "$S2" >> "$HOME/brain/projects/foo.md"
sd --name "$S2" --summary "s2"
[ "$RC" = 1 ] && has "$OUT" "✗ item:" && has "$OUT" "pass the time it shows as --item-updated" && ok "the item on nobody's list: refused, with the way out (--item-updated)" || bad "unlisted item: rc=$RC — $OUT"
sd --name "$S2" --summary "s2" --item-updated "$(( $(date +%s) - 3600 ))"
[ "$RC" = 1 ] && has "$OUT" "✗ item: board#44 last changed" && ok "--item-updated before the start: refused" || bad "item-updated old: rc=$RC — $OUT"
sd --name "$S2" --summary "s2" --item-updated "not a time"
[ "$RC" = 1 ] && has "$OUT" "neither an epoch nor an ISO time" && ok "--item-updated that is no time: said" || bad "item-updated junk: rc=$RC — $OUT"
touch "$HOME/msg-fail"
sd --name "$S2" --summary "s2" --item-updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
[ "$RC" != 0 ] && has "$OUT" "could not be sent to acme-main" && [ ! -e "$SIDE/$S2.done" ] && [ -z "$(sval "$S2" summary_sent_to)" ] && ok "--item-updated now (ISO): the checks hold, the send fails: no marker, the send not recorded" || bad "send fails: rc=$RC — $OUT / $(<"$SIDE/$S2.side")"
rm -f "$HOME/msg-fail"
sd --name "$S2" --summary "s2" --item-updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --summary-to gamma-foo-other
[ "$RC" = 0 ] && [ "$(nmsgs)" = 2 ] && [ -s "$SIDE/$S2.done" ] && [ "$(grep -c "^ARGS gamma-foo-other - --sender $S2\$" "$HOME/msgs.txt")" = 1 ] && ok "the retry succeeds, --summary-to sends to another agent" || bad "retry: rc=$RC msgs=$(nmsgs) — $OUT"
hasnt "$(tail -8 "$HOME/msgs.txt")" "[for Rowan]" && ok "no [for Rowan] line to an agent that is not a -main" || bad "for Rowan sent: $(tail -8 "$HOME/msgs.txt")"
# the page without a brain mirror: stackshot's last-change time
S3=gamma-foo-side-sedge12; mkrec "$S3" fork gamma-foo-lead projects/foo "" gamma-foo-lead "$(( $(date +%s) - 120 ))"
SALA_BRAIN_DIR="$HOME/nobrain" sd --name "$S3" --summary "s3"
[ "$RC" = 1 ] && has "$OUT" "– item: none on this session's record" && has "$OUT" "✗ page:" && ok "a fork with no item: the item check skipped and said; no brain mirror and no page-ts: the page refused" || bad "no mirror: rc=$RC — $OUT"
echo "{\"key\": \"projects/foo\", \"ts\": $(( $(date +%s) - 3600 ))}" > "$HOME/page-ts.json"
SALA_BRAIN_DIR="$HOME/nobrain" sd --name "$S3" --summary "s3"
[ "$RC" = 1 ] && has "$OUT" "has not changed since the session started" && ok "page-ts older than the start: refused" || bad "page-ts old: rc=$RC — $OUT"
SALA_BRAIN_DIR= sd --name "$S3" --summary "s3"   # unset (the default): no mirror at all, so the page-ts path, never a path under /
[ "$RC" = 1 ] && has "$OUT" "has not changed since the session started" && ok "SALA_BRAIN_DIR unset: no mirror is read; the page's last change from stackshot decides" || bad "no brain dir: rc=$RC — $OUT"
echo "{\"key\": \"projects/foo\", \"ts\": $(date +%s)}" > "$HOME/page-ts.json"
SALA_BRAIN_DIR="$HOME/nobrain" sd --name "$S3" --summary "s3"
[ "$RC" = 0 ] && has "$OUT" "the weaker proof" && [ -s "$SIDE/$S3.done" ] && ok "page-ts after the start: accepted, said as the weaker proof; the fork's summary went to the agent" || bad "page-ts new: rc=$RC — $OUT"
sd --name gamma-foo-nobody
[ "$RC" = 1 ] && has "$OUT" "is not a side session" && ok "a name with no side record: refused" || bad "not side: rc=$RC — $OUT"
sd --name "$S2" --item junk; [ "$RC" = 1 ] && has "$OUT" "board item id as shown" && ok "--item that is not board#N: refused" || bad "item junk: rc=$RC — $OUT"

echo "== side done: the header decision (-main marked at once; another agent plain, marked once on a front-agent refusal), --summary-to projects/<slug>, the name check"
tries() { local n; n=$(grep -c "^TRY" "$HOME/tries.txt" 2>/dev/null); echo "${n:-0}"; }
mkdone() {  # <name> → a session whose three checks hold (a fork with no item, a timeline line from it)
    mkrec "$1" fork gamma-foo-lead projects/foo "" gamma-foo-lead "$(( $(date +%s) - 120 ))"
    printf -- '- **%s** | %s — settled\n' "$TODAY" "$1" >> "$HOME/brain/projects/foo.md"
}
LOG="$SALA_LOG_DIR/salamander-side.log"
: > "$HOME/msgs.txt"; : > "$HOME/tries.txt"
H1=gamma-foo-side-fern21; mkdone "$H1"
sd --name "$H1" --summary "h1" --summary-to x-main
[ "$RC" = 0 ] && [ "$(tries)" = 1 ] && [ "$(sed -n 2p "$HOME/msgs.txt")" = "[for Rowan]" ] && [ -s "$SIDE/$H1.done" ] && ok "a target ending in -main: [for Rowan] on the first try, one attempt" || bad "x-main: rc=$RC tries=$(tries) — $OUT / $(<"$HOME/msgs.txt")"
: > "$HOME/msgs.txt"; : > "$HOME/tries.txt"; touch "$HOME/msg-refuse-front"
H2=gamma-foo-side-fern22; mkdone "$H2"
sd --name "$H2" --summary "h2 body" --summary-to example-foo-sharing
[ "$RC" = 0 ] && [ "$(tries)" = 2 ] && has "$(sed -n 1p "$HOME/tries.txt")" "first line: [side done] $H2" && has "$(sed -n 2p "$HOME/tries.txt")" "first line: [for Rowan]" \
    && [ "$(nmsgs)" = 1 ] && [ "$(sed -n 2p "$HOME/msgs.txt")" = "[for Rowan]" ] && has "$(<"$HOME/msgs.txt")" "h2 body" && [ -s "$SIDE/$H2.done" ] && [ "$(sval "$H2" summary_sent_to)" = example-foo-sharing ] \
    && ok "a front agent not named -main: first without the mark, refused, retried once with it, delivered, marker written" || bad "front retry: rc=$RC tries=$(tries) — $OUT / $(<"$HOME/tries.txt")"
has "$(<"$LOG")" "retrying once with it" && has "$(<"$LOG")" "delivered to example-foo-sharing with [for Rowan], on the second attempt" && has "$(<"$LOG")" "is a front agent of foo" && ok "the log: the refusal text, the retry and which attempt delivered" || bad "log: $(tail -5 "$LOG")"
: > "$HOME/msgs.txt"; : > "$HOME/tries.txt"; rm -f "$HOME/msg-refuse-front"
H2B=gamma-foo-side-fern26; mkdone "$H2B"
sd --name "$H2B" --summary "h2b" --summary-to example-foo-builder
[ "$RC" = 0 ] && [ "$(tries)" = 1 ] && hasnt "$(<"$HOME/msgs.txt")" "[for Rowan]" && has "$(<"$LOG")" "delivered to example-foo-builder without [for Rowan]" && ok "a background agent: delivered on the first try without the mark, no retry" || bad "plain: rc=$RC tries=$(tries) — $OUT"
: > "$HOME/msgs.txt"; : > "$HOME/tries.txt"; touch "$HOME/msg-refuse-other"
H3=gamma-foo-side-fern23; mkdone "$H3"
sd --name "$H3" --summary "h3" --summary-to example-foo-sharing
[ "$RC" != 0 ] && [ "$(tries)" = 1 ] && [ ! -s "$HOME/msgs.txt" ] && has "$OUT" "could not be sent to example-foo-sharing" && [ ! -e "$SIDE/$H3.done" ] && [ -z "$(sval "$H3" summary_sent_to)" ] && has "$(<"$LOG")" "the project page is locked" \
    && ok "a refusal with other text: not retried, dies, no marker, the output in the log" || bad "other refusal: rc=$RC tries=$(tries) — $OUT"
rm -f "$HOME/msg-refuse-other"; : > "$HOME/msgs.txt"; : > "$HOME/tries.txt"
H4=gamma-foo-side-fern24; mkdone "$H4"
sd --name "$H4" --summary "h4 body" --summary-to projects/notes
[ "$RC" = 0 ] && has "$OUT" "the summary was sent to projects/notes" && [ "$(tries)" = 1 ] && [ "$(sed -n 1p "$HOME/msgs.txt")" = "ARGS projects/notes - --sender $H4" ] && [ "$(sed -n 2p "$HOME/msgs.txt")" = "[side done] $H4, a side conversation forked from gamma-foo-lead, has finished its conversation with Rowan. Its summary:" ] \
    && hasnt "$(<"$HOME/msgs.txt")" "[for Rowan]" && has "$(<"$HOME/msgs.txt")" "h4 body" && [ -s "$SIDE/$H4.done" ] && ok "--summary-to projects/<slug>: accepted, the message unchanged, no [for Rowan]" || bad "projects target: rc=$RC — $OUT / $(<"$HOME/msgs.txt")"
H5=gamma-foo-side-fern25; mkdone "$H5"; : > "$HOME/tries.txt"; : > "$HOME/msgs.txt"
sd --name "$H5" --summary "h5" --summary-to example/wiki-sharing-x
[ "$RC" = 0 ] && [ "$(sed -n 1p "$HOME/msgs.txt")" = "ARGS example/wiki-sharing-x - --sender $H5" ] && hasnt "$(<"$HOME/msgs.txt")" "[for Rowan]" && ok "--summary-to <another dir>/<slug>: accepted, unmarked" || bad "other-dir target: rc=$RC — $OUT"
H6=gamma-foo-side-fern27; mkdone "$H6"; : > "$HOME/tries.txt"
for bad_to in "a b" "../x" "/x" "x/" "a//b" "projects/../x" "-x"; do
    sd --name "$H6" --summary "h6" --summary-to "$bad_to"
    [ "$RC" = 1 ] && has "$OUT" "--summary-to needs an agent's session name or a project key" && [ "$(tries)" = 0 ] && [ ! -e "$SIDE/$H6.done" ] && ok "--summary-to '$bad_to': refused, nothing sent" || bad "bad to '$bad_to': rc=$RC — $OUT"
done

echo "== side done: the message output file (sala-side-msg.*) is gone on every exit, a stop included"
SCR="$HOME/scratch"; mkdir -p "$SCR"; left() { ls -A "$SCR" 2>/dev/null; }
cat > "$HOME/fake-msg-hang" <<'EOF'
#!/bin/bash
cat > /dev/null; i=0; while [ ! -e "$HOME/msg-go" ] && [ $i -lt 100 ]; do sleep 0.2; i=$((i+1)); done; exit 1   # a send that does not answer (ended by msg-go, or after 20 s)
EOF
chmod +x "$HOME/fake-msg-hang"
H7=gamma-foo-side-fern31; mkdone "$H7"; : > "$HOME/msgs.txt"
OUT=$(TMPDIR="$SCR" "$SALA" side done --name "$H7" --summary "h7" --summary-to example-foo-builder 2>&1 </dev/null); RC=$?
[ "$RC" = 0 ] && [ -z "$(left)" ] && ok "a delivered summary leaves nothing in TMPDIR" || bad "delivered: rc=$RC left: $(left | tr '\n' ' ') — $OUT"
touch "$HOME/msg-refuse-other"; H8=gamma-foo-side-fern32; mkdone "$H8"
OUT=$(TMPDIR="$SCR" "$SALA" side done --name "$H8" --summary "h8" --summary-to example-foo-builder 2>&1 </dev/null); RC=$?
[ "$RC" != 0 ] && [ -z "$(left)" ] && ok "a refused summary leaves nothing in TMPDIR" || bad "refused: rc=$RC left: $(left | tr '\n' ' ')"
rm -f "$HOME/msg-refuse-other"
H9=gamma-foo-side-fern33; mkdone "$H9"; rm -f "$HOME/msg-go"
TMPDIR="$SCR" SALA_SIDE_MSG_CMD="$HOME/fake-msg-hang" "$SALA" side done --name "$H9" --summary "h9" --summary-to example-foo-builder >/dev/null 2>&1 </dev/null &
SP=$!
waitfor '[ -n "$(left)" ]' 40 && case "$(left)" in sala-side-msg.*) ok "a send in flight holds its output file (sala-side-msg.*) in TMPDIR" ;; *) bad "unexpected name: $(left | tr '\n' ' ')" ;; esac || bad "no output file while the send hangs"
kill -TERM "$SP" 2>/dev/null; wait "$SP" 2>/dev/null
[ -z "$(left)" ] && ok "stopped by SIGTERM: the output file is gone (the EXIT trap removed it)" || bad "left after the stop: $(left | tr '\n' ' ')"
: > "$HOME/msg-go"   # lets the hung send end

echo "== the retire gate: refused until the marker (plan and run), --skip-writeup the one bypass, a plain session untouched"
S4=gamma-foo-side-yarrow13
fakeenv "$(uuid 41)" "$S4"
run "$S4" --side --project projects/foo --item board#12 --no-confirm --cwd "$HOME/work"; fake_up "$S4"
OUT=$("$SALA" retire "$S4" --dry-run 2>&1); RC=$?
[ "$RC" = 1 ] && has "$OUT" "[dry-run] would refuse: '$S4' is a side session and its write-up is not done" && has "$OUT" "side done --name $S4" && has "$OUT" "--skip-writeup" && ok "retire --dry-run: refused, says what is missing and points at side done" || bad "retire dry: rc=$RC — $OUT"
OUT=$("$SALA" retire "$S4" --keep-web 2>&1); RC=$?
[ "$RC" != 0 ] && has "$OUT" "write-up is not done" && tmux has-session -t "=$S4" 2>/dev/null && ok "retire for real: refused, the session still there" || bad "retire real: rc=$RC — $OUT"
fakeenv "$(uuid 42)" sala-test-plain; PL=$("$SALA" spawn sala-test-plain --cwd "$HOME/work" 2>&1); fake_up sala-test-plain
OUT=$("$SALA" retire sala-test-plain --dry-run 2>&1); RC=$?
[ "$RC" = 0 ] && hasnt "$OUT" "side session" && ok "a plain session: the retire plan is as before" || bad "plain retire: rc=$RC — $OUT"
OUT=$("$SALA" retire "$S4" --keep-web --skip-writeup 2>&1); RC=$?
[ "$RC" = 0 ] && has "$OUT" "retiring the side session '$S4' without its write-up marker (--skip-writeup)" && has "$OUT" "retired '$S4'" && ! tmux has-session -t "=$S4" 2>/dev/null && ok "--skip-writeup: said, and retired" || bad "force: rc=$RC — $OUT"
[ -f "$SIDE/retired/$S4.side" ] && [ ! -f "$SIDE/$S4.side" ] && ok "the record moved to side/retired/" || bad "record after retire: $(ls -R "$SIDE")"
OUT=$("$SALA" retire "$S" --keep-web 2>&1); RC=$?
[ "$RC" = 0 ] && has "$OUT" "retired '$S'" && [ -f "$SIDE/retired/$S.done" ] && [ -f "$SIDE/retired/$S.side" ] && ok "a session with its marker: retired without --skip-writeup, record and marker moved" || bad "retire with marker: rc=$RC — $OUT"
OUT=$("$SALA" retire sala-test-plain --keep-web 2>&1); RC=$?
[ "$RC" = 0 ] && has "$OUT" "retired 'sala-test-plain'" && ok "a plain session retires as before" || bad "plain retire real: rc=$RC — $OUT"

echo "side: $([ "$fail" = 0 ] && echo pass || echo FAIL)"
exit $fail
