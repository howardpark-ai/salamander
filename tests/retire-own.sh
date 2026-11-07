#!/usr/bin/env bash
# A throwaway is retired with no words, by whoever may (the session that started a throwaway may end it with no words, and retiring a
# throwaway must never need the owner; lib/op.sh op_own_retire_ok and
# op_own_target_ok, lib/spawn.sh and common.sh A THROWAWAY'S SPAWNER, docs/session-registry.md). Checked here, with the compiled fake claude on a
# private tmux socket and an isolated HOME (no real session, pane or unit is touched, and nothing is queued on the live queue: SALA_OP_QUEUE=off,
# the state folder is under the temporary HOME):
#   - a bare `sala spawn` from a Claude session's pane records that session as the row's spawned_by; the same spawn from a plain shell
#     records none;
#   - `op retire NAME --from YOU` with no --words is queued when NAME is a throwaway (a live row, no project, no role, not a side session, on no
#     project's agents map, not the master, not YOU) and YOU may end it: its spawner; the master, when the name is a throwaway's (or the master
#     started it); or any session when it has no live spawner (none on the row, or the spawner's session is gone) and a throwaway's name
#     (scratch-*, *-check-*, *-test-*, *-probe-*); the marker says which rule (an empty words, a `nowords=` note) and `op --list` shows the note,
#     not an empty quote;
#   - (a review finding; the bypass flags are --busy, --skip-writeup, --self and --leave-items since Sun Nov 1st 2026, with --id and the old --force refused too) the bypass flags and --keep-web are never taken with no words (queue time, flag before or after the name, and the runner on
#     a marker edited by hand); the agents-map check FAILS CLOSED for the master and any-session doors: a stale, missing or unreadable project
#     record falls back to pages.py agent-listed (a stub here), and with no answer from either the retire is refused, while the spawner door still
#     queues; the master needs a throwaway's name unless it started the row; a pane with no row id anywhere passes only under a throwaway's name
#     with a fresh "unlisted" answer, whichever door let the caller in (a victim with no id renamed onto a dead row's name is refused);
#   - every other case keeps the refusal, and the refusal says when no words are allowed and why this one is not: a throwaway whose spawner is
#     live; a project agent (also with a throwaway name and no spawner); a side session; a name on the project record's agents map; the master; the
#     asking session itself; a row with no spawner or a dead one and a name that is not a throwaway's; a name that is not the row's own (its id);
#     a name with no row; another verb with no words;
#   - the caller is placed by PROCESS ANCESTRY (a pane process in tmux list-panes -a, a claude on the way up), never by TMUX_PANE or --from:
#     calls run as children of a driver pane process (`callin`) that is a copy of bash under the fake install folder, run through a symlink named claude (a real install's exe, comm claude); a plain shell, an orphaned (double-forked)
#     call, a person's pane with no claude above the call, and a claude child with TMUX_PANE set to another pane are all refused, and a
#     spawn from those records no spawner (or the pane's own);
#   - the target is bound to the row by its process (SALA_SESSION_ID = the row id): a victim renamed to a dead throwaway's name (with or without a
#     spawner on its row) is refused; a pane from before ids (no process carries one, a Claude Code process among them) is bound by its name, one
#     with no Claude in it is refused; with no tmux session of that name left the retire is queued;
#   - a process that only wears the name claude (a symlink to bash, a bash copy outside the account's install folder) is no caller; every
#     process in every pane of the target must carry the row's id (a child or a second window without it refuses);
#   - the runner judges a no-words retire again (marker ownrow=): a session replaced after queueing, a changed or deleted ownrow goes stuck
#     with nothing ended and, even with SALA_OP_STUCK=on, no claude -p helper started (it could run salamander retire unchecked); a child that
#     exited mid-read is skipped; the untouched one is retired;
#   - THE THROWAWAY TAG: a bare spawn (from a Claude session or a plain shell) writes throwaway=1 on the row, a spawn with
#     --project/--role or --side never does, and setting a project, a role or a side mark (sessions set, sessions tag) takes it off; any live session
#     but the row itself and the master retires a tagged row with no words, its spawner alive or not, under any name (the master too); a tag written onto a row
#     that has a project, a side mark or an agents-map entry opens nothing, nor does it lift the bypass-flag/--keep-web refusal or the fail-closed agents-map
#     check; the rows the rest of this suite makes have the tag taken off by its `spawn` helper (they stand in for rows from before the tag) and keep the earlier
#     rules; the runner ends a tagged row (retire's own idle check, no --busy);
#   - the owner's words still queue any retire as before;
#   - THE REASON DOOR (lib/op.sh op_words_policy, op_reason_revive_ok; the same process-ancestry placement of the caller as above): `op revive --only NAME… [--force]` with
#     `--item board#N` or `--why "<text>"` and no --words is queued from any live Claude session (SALA_OP_REASON_FROM empty), for live registry rows that are neither the
#     master nor the asker: the marker (item= or reason=, one ownrow= per session in order, the nowords note), `op --list`, `--status` and the log; refused with nothing queued
#     for no reason, a bad item (board#x, #5, 5, two lines), a why of two words / empty / two lines / over 200 characters, both together, a sweep, --rescue and --lane-default,
#     --item or --why on any other verb, a name with no row or a row's id, the asker or the master (also among several), a sender outside SALA_OP_REASON_FROM, a plain shell, a
#     detached call, a person's pane, another session's pane, `--auto`; every other verb with no words keeps the plain refusal and retire's door is unchanged; the policy table
#     (op_words_policy) for each verb; the stuck helper's brief; the runner judges it again (op --run by hand) and goes stuck with nothing relaunched and no claude -p on a changed
#     row id, a lost or malformed reason, an extra or removed session, a bad shape, a sender no longer allowed, a session that became the master or the sender; the untouched
#     marker relaunches that one session and no other.
# Usage: bash tests/retire-own.sh   (exit 0 = pass; ~3 min)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_SESSION_ID SALA_MASTER SALA_SET SALA_SET_SELF SALA_RECYCLE SALA_RETRY_WORKER SALA_LOCK_WHO SALA_LOCK_WAIT \
      SALA_RELAUNCH_KIND SALA_FLEET_HOSTS SALA_CGROUP_FILE SALA_OP_QUEUE SALA_OP_REBOOT SALA_OP_STUCK SALA_REBOOT_HOOKS SALA_NO_RELAUNCH \
      SALA_STACKSHOT_DIR SALA_AGENT_CHECK_SCRIPT SALA_PROJECT_RECORD
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"   # short timings, ok/bad/waitfor, fake_up, tmux_socket_rm, as_op_unit
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null
exec 8< "$HOME"; flock -n 8   # the temporary folder is locked while the suite runs (systemd-tmpfiles ageing honours the flock)
as_op_unit
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects/x" "$HOME/.local/bin" "$HOME/.local/share/tmux/resurrect" "$HOME/work" "$HOME/anc" "$HOME/.local/share/claude/versions"
touch "$HOME/.claude/salamander-rc.stopped"      # no Remote Control server in the sandbox
# The fake claude lives where a real Claude Code install does (~/.local/share/claude/versions/<v>, the launcher ~/.local/bin/claude a symlink to it):
# the caller check trusts a claude by that exe path (common.sh claude_exe_trusted), and under a test's temporary HOME that is $HOME's own folder.
cc -o "$HOME/.local/share/claude/versions/2.1.0-test" "$ROOT/tests/fake-claude.c" || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (an EXIT trap may not exist yet here)
ln -sf "$HOME/.local/share/claude/versions/2.1.0-test" "$HOME/.local/bin/claude"
export PATH="$HOME/.local/bin:$PATH"; export FAKE_LOG="$HOME/fake.log"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="cat >> $POSTS"   # no post leaves the box
export SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_LEDGER_CALLER=retire-own-test
export SALA_OP_STUCK=off   # a stuck operation (the run-time re-check below) is recorded, and no claude -p is started for it
export SALA_OP_QUEUE=off   # markers are written and nothing starts them
export SALA_PROJECT_RECORD_MAX_AGE=3600   # the project record the suite writes (record_set) stays fresh for the ~2 minutes it runs; a "stale" one is two days old
SALA="$ROOT/bin/salamander"; SOCK="sala-retire-own-$$"; T="tmux -L $SOCK -f /dev/null"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # this server stands in for the fleet's (common.sh, on_fleet_server)
cleanup() {
    local e; $T kill-server 2>/dev/null; tmux_socket_rm; sleep 1
    for e in /proc/[0-9]*; do [ "$e/exe" -ef "$HOME/.local/bin/claude" ] && kill -9 "${e#/proc/}" 2>/dev/null; done   # only our own fakes, by their exe
    exec 8<&-; rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux
. "$ROOT/lib/common.sh"; REG="$SALA_SESSIONS_FILE"
OPS="$SALA_STATE_DIR/ops"
record_set() {  # fresh|stale|missing|garbage → stackshot's project record (what common.sh project_record_agent reads) in the state the case needs.
    # fresh = written now, one project (projects/test) whose agents map lists test-main and sala-test-mapped, so every other name is "on no agents map";
    # stale = the same content written two days ago (older than SALA_PROJECT_RECORD_MAX_AGE); missing = no file; garbage = a file that is not JSON.
    local f="$HOME/.local/state/stackshot/projects.json"; mkdir -p "${f%/*}"
    case "$1" in
        missing) rm -f "$f" ;;
        garbage) printf 'not json {' > "$f" ;;
        *) python3 -I - "$f" "$1" <<'PY'
import datetime, json, sys
age = 2 * 86400 if sys.argv[2] == "stale" else 0
when = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=age)).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump({"schema": 1, "generated": when, "projects": {"prj_example": {"id": "prj_example", "key": "projects/test", "keeper": "x",
    "agents": {"test-main": {"front": True, "role": "main", "mandate_line": "main"}, "sala-test-mapped": {"front": False, "role": "builder", "mandate_line": "builds"}}}},
    "by_key": {"projects/test": "prj_example"}}, open(sys.argv[1], "w"))
PY
        ;;
    esac
}
stub_pages() {  # <name> <exit code> <line> → a stand-in for stackshot's pages.py (SALA_AGENT_CHECK_SCRIPT): `agent-listed NAME` prints the line and exits with the code
    printf 'import sys\nprint(%s)\nsys.exit(%s)\n' "'$3'" "$2" > "$HOME/pages-$1.py"; echo "$HOME/pages-$1.py"
}
record_set fresh   # the default for the suite: a fresh record that lists no throwaway
tmux new-session -d -s keep-alive; tmux set-environment -g FAKE_LOG "$FAKE_LOG"
# THE CALLERS. The caller is placed by process ancestry (common.sh ancestry_session), so a "Claude session's call" has to run under a process
# named claude that is the process of a pane (or sits under it). A DRIVER is that process: a script named claude (a script's comm is its
# file name) that is the pane process of a window of the asking session and runs each command file it is handed as its own child, writing
# the output and the status beside it. callin <session> <argv…> hands it one and waits. The driver of a session whose name is "sala-test-human"
# is named human instead: a person's shell in a pane, with no claude above the call.
cat > "$HOME/drv-claude" <<'EOF'
#!/bin/bash
# the argument is the folder of command files (<id>.cmd = one command line); each runs as a CHILD of this process, never exec'd
d=$1
while :; do
    for f in "$d"/*.cmd; do
        [ -e "$f" ] || continue
        b=${f%.cmd}
        bash "$f" > "$b.out" 2>&1; echo $? > "$b.rc.tmp"; mv "$b.rc.tmp" "$b.rc"; rm -f "$f"
    done
    sleep 0.2
done
EOF
# The claude driver is a COPY OF bash installed in the versions folder and started through a symlink named claude (comm claude, exe a trusted path),
# the way the launcher starts a real one; the human driver is a plain script named human.
mkdir -p "$HOME/drv" "$HOME/drvh" "$HOME/evil"; cp "$(command -v bash)" "$HOME/.local/share/claude/versions/drv-bash"; ln -sf "$HOME/.local/share/claude/versions/drv-bash" "$HOME/drv/claude"
cp "$HOME/drv-claude" "$HOME/drvh/human"; chmod +x "$HOME/drvh/human"
ln -sf "$(command -v bash)" "$HOME/evil/claude"   # a symlink to /bin/bash named claude: comm claude, exe NOT under any Claude install
driver_up() {  # <session> [claude|human] → a driver window in that tmux session (made if the session is not there yet)
    local s=$1 kind=${2:-claude} exe
    mkdir -p "$HOME/drv-calls/$s"; if [ "$kind" = claude ]; then exe="$HOME/drv/claude $HOME/drv-claude"; else exe="$HOME/drvh/human"; fi
    if tmux has-session -t "=$s" 2>/dev/null; then tmux new-window -d -t "=$s:" "$exe $HOME/drv-calls/$s"; else tmux new-session -d -s "$s" "$exe $HOME/drv-calls/$s"; fi
}
callin() {  # <session> <argv…> → OUT, RC of that command run as a child of the session's driver (a call from inside that pane)
    local s=$1 id f; shift; id=$(date +%s%N)-$RANDOM; f="$HOME/drv-calls/$s/$id"
    printf '%q ' "$@" > "$f.tmp"; echo >> "$f.tmp"; mv "$f.tmp" "$f.cmd"
    waitfor "[ -e '$f.rc' ]" 300 || { OUT="(the driver in $s did not answer)"; RC=99; return; }
    OUT=$(<"$f.out"); RC=$(<"$f.rc"); rm -f "$f.out" "$f.rc"
}
spawn() {  # <name> <uuid> [session] → `sala spawn` of a bare throwaway; run inside that session's driver when given (a Claude session's call), else from this plain shell.
    # Every row it makes stands in for one made BEFORE the throwaway tag: the tag the real spawn wrote is taken off again, unless TAGGED=1, so the cases of
    # the earlier rules below keep testing the untagged rows' rules. The tag itself is checked in "the throwaway tag" below, on rows spawned with TAGGED=1.
    local rc
    tmux set-environment -g FAKE_SESSION_ID "$2"; tmux set-environment -g FAKE_NAME "$1"
    if [ -n "${3:-}" ]; then callin "$3" "$SALA" spawn "$1" --cwd "$HOME/work"; printf '%s\n' "$OUT"; rc=$RC; else "$SALA" spawn "$1" --cwd "$HOME/work" 2>&1; rc=$?; fi
    [ "${TAGGED:-0}" = 1 ] || sessions_set "$1" throwaway=
    return "$rc"
}
pane() { tmux display -p -t "$1" '#{pane_id}'; }
rowq() {  # <name> <field> → that field of the newest live row of that name ("" when null, <none> with no row)
    python3 - "$REG" "$1" "$2" <<'PY'
import json, sys
f, name, what = sys.argv[1:4]
try: rows = [r for r in json.load(open(f))["sessions"].values() if r["name"] == name and r["state"] == "live"]
except Exception: rows = []
rows.sort(key=lambda r: r["created"])
if not rows: print("<none>"); sys.exit()
v = rows[-1].get(what)
print("" if v is None else v)
PY
}
mvals() { local f="$OPS/$1.op"; awk -F= -v k="$2" '$1==k {print substr($0, length(k)+2)}' "$f" 2>/dev/null; }   # <id> <key> -> every value of it
mval() { local f="$OPS/$1.op"; awk -F= -v k="$2" '$1==k {print substr($0, length(k)+2); exit}' "$f" 2>/dev/null; }   # <id> <key> → a marker's value
queued() { ls "$OPS"/*.op 2>/dev/null | wc -l; }
dropall() { local f; for f in "$OPS"/*.op; do [ -e "$f" ] && rm -f "$f"; done; true; }   # a queued marker names its session: cleared between cases (nothing runs them)
enq_as() {  # <session> <op args…> → OUT, RC, ID of `sala op` called from inside that session's driver (SALA_MASTER passed on when set); "" = this plain shell
    local p=$1 l; shift
    if [ -n "$p" ]; then callin "$p" env ${SALA_MASTER:+SALA_MASTER=$SALA_MASTER} ${SALA_AGENT_CHECK_SCRIPT:+SALA_AGENT_CHECK_SCRIPT=$SALA_AGENT_CHECK_SCRIPT} ${SALA_OP_REASON_FROM:+SALA_OP_REASON_FROM="$SALA_OP_REASON_FROM"} "$SALA" op "$@"; else OUT=$("$SALA" op "$@" 2>&1); RC=$?; fi
    ID=""; while IFS= read -r l; do if [[ $l =~ ^queued\ op\ ([0-9-]*): ]]; then ID=${BASH_REMATCH[1]}; break; fi; done <<< "$OUT"
}
NOWORDS="words: none (throwaway, retired by its spawner)"; NW_MASTER="words: none (throwaway, retired by the master)"; NW_ANY="words: none (throwaway with no tag, retired by any session: no live spawner)"; NW_TAG="words: none (throwaway tag set at spawn, retired by any session)"

echo "== setup: the asking sessions owner and other"
out=$(spawn sala-test-owner "$(uuid 1)"); [ $? = 0 ] && tmux has-session -t =sala-test-owner 2>/dev/null || bad "spawn owner: $out"
out=$(spawn sala-test-other "$(uuid 2)"); [ $? = 0 ] && tmux has-session -t =sala-test-other 2>/dev/null || bad "spawn other: $out"
fake_up sala-test-owner sala-test-other || exit 1
PO=sala-test-owner; PX=sala-test-other   # the asking sessions' names; their calls run in a driver window each (above)
PANE_O=$(pane sala-test-owner:0); PANE_X=$(pane sala-test-other:0)
[ -n "$PANE_O" ] && [ -n "$PANE_X" ] && [ "$PANE_O" != "$PANE_X" ] && ok "two sessions, two panes: owner $PANE_O, other $PANE_X" || { bad "panes: '$PANE_O' '$PANE_X'"; exit 1; }
driver_up sala-test-owner; driver_up sala-test-other; driver_up sala-test-human human
callin sala-test-owner bash -c 'echo up'; [ "$RC" = 0 ] && [ "$OUT" = up ] && ok "a call runs inside owner's driver window" || { bad "driver: rc=$RC $OUT"; exit 1; }

echo "== spawn records the spawning Claude session on a bare throwaway's row, and only then"
out=$(spawn sala-test-own1 "$(uuid 11)" "$PO"); rc=$?
[ "$rc" = 0 ] && [ "$(rowq sala-test-own1 spawned_by)" = sala-test-owner ] && ok "spawned from owner's pane: spawned_by = sala-test-owner" || bad "own1: rc=$rc spawned_by='$(rowq sala-test-own1 spawned_by)' $out"
out=$(spawn sala-test-own2 "$(uuid 12)" "$PO"); [ $? = 0 ] && [ "$(rowq sala-test-own2 spawned_by)" = sala-test-owner ] && ok "a second one from owner: the same" || bad "own2: '$(rowq sala-test-own2 spawned_by)' $out"
out=$(spawn sala-test-theirs "$(uuid 13)" "$PX"); [ $? = 0 ] && [ "$(rowq sala-test-theirs spawned_by)" = sala-test-other ] && ok "spawned from other's pane: spawned_by = sala-test-other" || bad "theirs: '$(rowq sala-test-theirs spawned_by)' $out"
out=$(spawn sala-test-nospawn "$(uuid 14)"); [ $? = 0 ] && [ "$(rowq sala-test-nospawn spawned_by)" = "" ] && [ "$(rowq sala-test-nospawn id)" != "<none>" ] && ok "spawned from a plain shell: a live row with no spawned_by" || bad "nospawn: '$(rowq sala-test-nospawn spawned_by)' $out"
out=$(spawn sala-plain-nospawn "$(uuid 18)"); [ $? = 0 ] && [ "$(rowq sala-plain-nospawn spawned_by)" = "" ] && ok "the same under a name that is no throwaway's (sala-plain-nospawn)" || bad "plain-nospawn: '$(rowq sala-plain-nospawn spawned_by)' $out"
[ "$(rowq sala-test-owner spawned_by)" = "" ] && ok "owner and other, started from a shell, have none either" || bad "owner: '$(rowq sala-test-owner spawned_by)'"
# the other kinds of row: started by owner like any throwaway, then given what the real spawns set
out=$(spawn sala-test-proj "$(uuid 15)" "$PO"); out2=$(spawn sala-test-sidey "$(uuid 16)" "$PO"); out3=$(spawn sala-test-mast "$(uuid 17)" "$PO")
sessions_set sala-test-proj project=projects/test role=back
sessions_set sala-test-sidey side=1
[ "$(rowq sala-test-proj spawned_by)" = sala-test-owner ] && [ "$(rowq sala-test-sidey spawned_by)" = sala-test-owner ] && [ "$(rowq sala-test-mast spawned_by)" = sala-test-owner ] && [ "$(rowq sala-test-proj project)" = projects/test ] && [ "$(rowq sala-test-sidey side)" = 1 ] \
    && ok "three more of owner's, made into a project agent and a side session by setting their fields (the third stands in for the master below)" || bad "rows: spawned_by $(rowq sala-test-proj spawned_by) $(rowq sala-test-sidey spawned_by) $(rowq sala-test-mast spawned_by) / proj=$(rowq sala-test-proj project) side=$(rowq sala-test-sidey side)"
sessions_set sala-test-owner spawned_by=sala-test-owner   # an odd row: owner marked as its own spawner

echo "== own throwaway: queued with no words, the marker says so"
enq_as "$PO" retire sala-test-own1 --from sala-test-owner
[ "$RC" = 0 ] && [ -n "$ID" ] && ok "queued (exit 0): $(head -1 <<< "$OUT")" || bad "own: rc=$RC — $OUT"
if [ -n "$ID" ]; then
    [ "$(mval "$ID" verb)" = retire ] && [ "$(mval "$ID" arg)" = sala-test-own1 ] && [ "$(mval "$ID" from)" = sala-test-owner ] && [ -z "$(mval "$ID" words)" ] && [ "$(mval "$ID" nowords)" = "$NOWORDS" ] && [ "$(mval "$ID" state)" = queued ] \
        && ok "the marker: retire sala-test-own1, from sala-test-owner, words empty, nowords='$NOWORDS'" || bad "marker: $(<"$OPS/$ID.op")"
    has "$OUT" "$NOWORDS" && ok "the queued line carries the note" || bad "queued line: $OUT"
    LIST=$("$SALA" op --list 2>&1)
    has "$LIST" "$NOWORDS" && ! has "$LIST" '""' && ok "op --list shows the note, not an empty quote" || bad "op --list: $LIST"
fi
dropall
enq_as "$PO" retire sala-test-own1 --from sala-test-owner --words "   "
[ "$RC" = 0 ] && [ -n "$ID" ] && [ "$(mval "$ID" nowords)" = "$NOWORDS" ] && ok "blank words are no words: the same rule" || bad "blank words: rc=$RC — $OUT"
dropall

echo "== every other case keeps the refusal (nothing queued; the message says when no words are allowed, and why not here)"
refuse() {  # <why> <fragment of the reason> <pane> <op args…>
    local why=$1 frag=$2 p=$3; shift 3
    enq_as "$p" "$@"
    if [ "$RC" != 0 ] && [ "$(queued)" = 0 ] && has "$OUT" "no --words" && has "$OUT" "YOU may end the one YOU started" && has "$OUT" "refused here: " && has "$OUT" "$frag"; then ok "refused: $why"
    else bad "$why: rc=$RC queued=$(queued) — $OUT"; dropall; fi
}
refuse "another live session's throwaway" "was started by 'sala-test-other', who is still live" "$PO" retire sala-test-theirs --from sala-test-owner
refuse "the other asker, for owner's throwaway (owner is live)" "was started by 'sala-test-owner', who is still live" "$PX" retire sala-test-own2 --from sala-test-other
refuse "a project agent (even one the asker started)" "is a project agent, not a throwaway" "$PO" retire sala-test-proj --from sala-test-owner
refuse "a side session (even one the asker started)" "is a side session" "$PO" retire sala-test-sidey --from sala-test-owner
refuse "a row with no spawned_by under a name that is no throwaway's" "has no spawner on its registry row and its name is not a throwaway's" "$PO" retire sala-plain-nospawn --from sala-test-owner
refuse "the asking session itself (its row names itself)" "is the asking session itself" "$PO" retire sala-test-owner --from sala-test-owner
refuse "a name with no row" "has no live registry row under that exact name" "$PO" retire sala-test-ghost --from sala-test-owner
refuse "the row's id in place of its name" "is not the registry row's own name" "$PO" retire "$(rowq sala-test-own2 id)" --from sala-test-owner
SALA_MASTER=sala-test-mast refuse "the master (even one the asker started)" "is the master session" "$PO" retire sala-test-mast --from sala-test-owner
enq_as "$PO" rename sala-test-own2 sala-test-renamed --from sala-test-owner
[ "$RC" != 0 ] && [ "$(queued)" = 0 ] && has "$OUT" "no --words" && ! has "$OUT" "refused here: " && ok "another verb on owner's own throwaway (rename): still needs words" || { bad "rename: rc=$RC — $OUT"; dropall; }
enq_as "$PO" retire sala-test-own2 sala-test-own1 --from sala-test-owner   # two names: not the retire shape
[ "$RC" != 0 ] && [ "$(queued)" = 0 ] && ok "a retire of two names is refused by the shape" || { bad "two names: rc=$RC — $OUT"; dropall; }

echo "== Rowan's words still queue any retire as before"
enq_as "$PO" retire sala-test-theirs --from sala-test-owner --words "retire theirs"
[ "$RC" = 0 ] && [ -n "$ID" ] && [ "$(mval "$ID" words)" = "retire theirs" ] && [ -z "$(mval "$ID" nowords)" ] && ok "another session's throwaway, with words: queued, words kept, no nowords note" || bad "words: rc=$RC — $OUT"
dropall

echo "== the caller is placed by process ancestry, never by TMUX_PANE or --from (a review finding)"
OUT=$("$SALA" op retire sala-test-own1 --from sala-test-owner 2>&1); RC=$?
[ "$RC" != 0 ] && [ "$(queued)" = 0 ] && has "$OUT" "process ancestry" && has "$OUT" "refused here: " && ok "a plain shell with no words: refused (a human there passes --words)" || { bad "plain shell: rc=$RC queued=$(queued) — $OUT"; dropall; }
OUT=$(TMUX_PANE="$PANE_O" "$SALA" op retire sala-test-own1 --from sala-test-owner 2>&1); RC=$?
[ "$RC" != 0 ] && [ "$(queued)" = 0 ] && has "$OUT" "process ancestry" && ok "a plain shell with TMUX_PANE set to owner's pane and --from owner: refused" || { bad "plain shell, spoofed pane: rc=$RC queued=$(queued) — $OUT"; dropall; }
callin sala-test-other env TMUX_PANE="$PANE_O" "$SALA" op retire sala-test-own1 --from sala-test-owner
[ "$RC" != 0 ] && [ "$(queued)" = 0 ] && has "$OUT" "this call runs in session 'sala-test-other'" && ok "a claude child in other's pane with TMUX_PANE = owner's pane, --from owner: refused (placed in other, not owner)" || { bad "spoofed pane: rc=$RC queued=$(queued) — $OUT"; dropall; }
callin sala-test-other env TMUX_PANE="$PANE_O" "$SALA" op retire sala-test-own1 --from sala-test-other
[ "$RC" != 0 ] && [ "$(queued)" = 0 ] && has "$OUT" "was started by 'sala-test-owner', who is still live" && ok "the same call as --from other: it is other's own name now, and owner (live) still owns its throwaway" || { bad "spoofed pane as other: rc=$RC queued=$(queued) — $OUT"; dropall; }
callin sala-test-human env TMUX_PANE="$PANE_O" "$SALA" op retire sala-test-own1 --from sala-test-owner
[ "$RC" != 0 ] && [ "$(queued)" = 0 ] && has "$OUT" "process ancestry" && ok "a person's shell in a pane (no claude above the call), TMUX_PANE spoofed: refused" || { bad "human pane: rc=$RC queued=$(queued) — $OUT"; dropall; }
callin sala-test-owner env -u TMUX_PANE "$SALA" op retire sala-test-own1 --from sala-test-owner
[ "$RC" = 0 ] && [ "$(queued)" = 1 ] && ok "a claude child in owner's pane with no TMUX_PANE at all: queued (the pane is found by ancestry)" || { bad "no TMUX_PANE in a real pane: rc=$RC queued=$(queued) — $OUT"; }
dropall
rm -f "$HOME/orph.out"
callin sala-test-owner bash -c '( ( sleep 0.5; "$1" op retire sala-test-own1 --from sala-test-owner > "$2" 2>&1; echo "rc=$?" >> "$2" ) & )' _ "$SALA" "$HOME/orph.out"
waitfor "grep -q '^rc=' '$HOME/orph.out' 2>/dev/null" 60 || bad "the orphaned call did not end"
OUT=$(<"$HOME/orph.out")
has "$OUT" "rc=1" && [ "$(queued)" = 0 ] && has "$OUT" "process ancestry" && ok "an orphaned call (double fork, adopted by init) from owner's pane, --from owner: refused" || { bad "orphan: $OUT"; dropall; }
tmux set-environment -g FAKE_SESSION_ID "$(uuid 31)"; tmux set-environment -g FAKE_NAME sala-test-spoofed
callin sala-test-other env TMUX_PANE="$PANE_O" "$SALA" spawn sala-test-spoofed --cwd "$HOME/work"
[ "$RC" = 0 ] && [ "$(rowq sala-test-spoofed spawned_by)" = sala-test-other ] && ok "spawn from other's pane with TMUX_PANE = owner's: spawned_by is other (the pane's process), not owner" || bad "spoofed spawn: rc=$RC spawned_by='$(rowq sala-test-spoofed spawned_by)' $OUT"
tmux set-environment -g FAKE_SESSION_ID "$(uuid 32)"; tmux set-environment -g FAKE_NAME sala-test-byhuman
callin sala-test-human env TMUX_PANE="$PANE_O" "$SALA" spawn sala-test-byhuman --cwd "$HOME/work"
[ "$RC" = 0 ] && [ "$(rowq sala-test-byhuman spawned_by)" = "" ] && [ "$(rowq sala-test-byhuman id)" != "<none>" ] && ok "spawn from a person's pane (no claude), TMUX_PANE spoofed: no spawned_by" || bad "human spawn: rc=$RC spawned_by='$(rowq sala-test-byhuman spawned_by)' $OUT"

echo "== a session renamed to a dead throwaway's name is not that throwaway (a review finding)"
out=$(spawn sala-test-own3 "$(uuid 21)" "$PO"); [ $? = 0 ] && [ "$(rowq sala-test-own3 spawned_by)" = sala-test-owner ] && ok "owner's third throwaway, row live and spawned_by owner" || bad "own3: '$(rowq sala-test-own3 spawned_by)' $out"
OWN3_ID=$(rowq sala-test-own3 id)
tmux kill-session -t =sala-test-own3   # it dies; its row stays live
out=$(spawn sala-test-victim "$(uuid 22)"); [ $? = 0 ] && [ -n "$OWN3_ID" ] && [ "$(rowq sala-test-victim id)" != "$OWN3_ID" ] && ok "a victim session of its own (its pane carries its own row id)" || bad "victim: $out"
tmux rename-session -t =sala-test-victim sala-test-own3
enq_as "$PO" retire sala-test-own3 --from sala-test-owner
[ "$RC" != 0 ] && [ "$(queued)" = 0 ] && has "$OUT" "is not the throwaway on that registry row" && ok "the victim renamed to the dead throwaway's name: refused, nothing queued" || { bad "renamed victim: rc=$RC queued=$(queued) — $OUT"; dropall; }
tmux kill-session -t =sala-test-own3
tmux new-session -d -s sala-test-own3 "sleep 300"   # a session of that name that sala never spawned: no SALA_SESSION_ID
enq_as "$PO" retire sala-test-own3 --from sala-test-owner
[ "$RC" != 0 ] && [ "$(queued)" = 0 ] && has "$OUT" "carries no row id on any process" && ok "a session of that name with no row id and no Claude in it: refused" || { bad "id-less session: rc=$RC queued=$(queued) — $OUT"; dropall; }
tmux kill-session -t =sala-test-own3
enq_as "$PO" retire sala-test-own3 --from sala-test-owner
[ "$RC" != 0 ] && [ "$(queued)" = 0 ] && has "$OUT" "sala forget-row sala-test-own3" && ok "with no tmux session of that name left: retire is refused at the plan and names forget-row (the row is forget-row's job now)" || { bad "dead throwaway: rc=$RC queued=$(queued) — $OUT"; dropall; }
dropall

echo "== a process that merely wears the name claude is not a Claude session (a review finding: comm alone was enough)"
# Session A places a window into session B's tmux whose process is a symlink to bash named claude (comm claude, exe /bin/bash), and has it run
# `sala op retire <B's throwaway> --from B` with no words. Before: placed as B and queued. Now: the exe must be a Claude install's, so refused.
evil_try() {  # <label> <exe> → OUT of `sala op retire … --from owner` run by that exe as the pane process of a window in owner's session
    local label=$1 exe=$2
    rm -f "$HOME/evil.out"
    cat > "$HOME/evil-cmd.sh" <<EOF
"$SALA" op retire sala-test-own1 --from sala-test-owner > "$HOME/evil.out" 2>&1
echo "rc=\$?" >> "$HOME/evil.out"
EOF
    tmux new-window -d -t =sala-test-owner: "$exe $HOME/evil-cmd.sh"
    waitfor "grep -q '^rc=' '$HOME/evil.out' 2>/dev/null" 60 || bad "$label: the call did not end"
    OUT=$(<"$HOME/evil.out")
}
evil_try "symlink to bash" "$HOME/evil/claude"
has "$OUT" "rc=1" && [ "$(queued)" = 0 ] && has "$OUT" "process ancestry" && ok "a symlink to bash named claude, run as a window of owner's session: refused (comm claude, exe /bin/bash)" || { bad "evil claude: $OUT"; dropall; }
mkdir -p "$HOME/evil2/claude/versions"; cp "$(command -v bash)" "$HOME/evil2/claude/versions/9.9.9"; mkdir -p "$HOME/evil2/bin"; ln -sf "$HOME/evil2/claude/versions/9.9.9" "$HOME/evil2/bin/claude"
evil_try "bash in a folder named like an install" "$HOME/evil2/bin/claude"
has "$OUT" "rc=1" && [ "$(queued)" = 0 ] && has "$OUT" "process ancestry" && ok "a bash copy under .../claude/versions/ that is not this account's install: refused" || { bad "evil versions copy: $OUT"; dropall; }
callin sala-test-owner "$SALA" op retire sala-test-own1 --from sala-test-owner
[ "$RC" = 0 ] && [ "$(queued)" = 1 ] && ok "the same call from owner's real claude driver (exe under the install folder): queued" || bad "control: rc=$RC queued=$(queued) — $OUT"
dropall

echo "== the target is bound by every process in its panes, not one (a review finding)"
out=$(spawn sala-test-own4 "$(uuid 41)" "$PO"); [ $? = 0 ] && [ -n "$(rowq sala-test-own4 id)" ] && ok "owner's fourth throwaway" || bad "own4: $out"
W=$(tmux new-window -d -P -F '#{window_id}' -t =sala-test-own4: "bash -c 'env -u SALA_SESSION_ID sleep 3141; true'")
waitfor "pgrep -f 'sleep [3]141' >/dev/null" 30 || bad "the child without the id did not start"
enq_as "$PO" retire sala-test-own4 --from sala-test-owner
[ "$RC" != 0 ] && [ "$(queued)" = 0 ] && has "$OUT" "is not the throwaway on that registry row" && ok "a pane's child without the row id (the pane process has it): refused" || { bad "child without id: rc=$RC queued=$(queued) — $OUT"; dropall; }
tmux kill-window -t "$W"; waitfor "! pgrep -f 'sleep [3]141' >/dev/null" 30
W=$(tmux new-window -d -P -F '#{window_id}' -t =sala-test-own4: "env -u SALA_SESSION_ID sleep 3142")
waitfor "pgrep -f 'sleep [3]142' >/dev/null" 30 || bad "the second window did not start"
enq_as "$PO" retire sala-test-own4 --from sala-test-owner
[ "$RC" != 0 ] && [ "$(queued)" = 0 ] && has "$OUT" "is not the throwaway on that registry row" && ok "another window of the session whose pane process lacks the id: refused" || { bad "window without id: rc=$RC queued=$(queued) — $OUT"; dropall; }
tmux kill-window -t "$W"; waitfor "! pgrep -f 'sleep [3]142' >/dev/null" 30
enq_as "$PO" retire sala-test-own4 --from sala-test-owner
[ "$RC" = 0 ] && [ "$(queued)" = 1 ] && ok "with those windows gone: queued" || bad "own4 clean: rc=$RC queued=$(queued) — $OUT"
dropall

echo "== the runner judges the retire again before it ends anything (a review finding)"
dval() { awk -F= -v k="$2" '$1==k {print substr($0, length(k)+2); exit}' "$OPS/done/$1.op" 2>/dev/null; }   # <id> <key> → a value on the archived marker
runop() { "$SALA" op --run "$1" > "$HOME/run.out" 2>&1; echo $?; }   # the unit's main process, run by hand (SALA_OP_QUEUE=off starts nothing)
out=$(spawn sala-test-own5 "$(uuid 51)" "$PO"); R5=$(rowq sala-test-own5 id)
enq_as "$PO" retire sala-test-own5 --from sala-test-owner; ID5=$ID
[ "$RC" = 0 ] && [ -n "$ID5" ] && [ "$(mval "$ID5" ownrow)" = "$R5" ] && [ -n "$R5" ] && ok "the marker carries the row id it was queued for (ownrow=$R5)" || bad "ownrow: rc=$RC id=$ID5 marker: $(cat "$OPS/$ID5.op" 2>/dev/null)"
tmux kill-session -t =sala-test-own5; waitfor "! tmux has-session -t =sala-test-own5 2>/dev/null" 20
tmux new-session -d -s sala-test-own5 "sleep 300"   # another session under that name, started by nobody: no row id
rc=$(runop "$ID5")
[ "$(dval "$ID5" state)" = stuck ] && has "$(dval "$ID5" result)" "carries no row id on any process" && has "$(dval "$ID5" result)" "nothing was ended" && ok "queued, then the session replaced: the run goes stuck with the reason (rc=$rc)" || bad "run after replace: rc=$rc marker: $(cat "$OPS/done/$ID5.op" "$OPS/$ID5.op" 2>/dev/null | tail -8)"
tmux has-session -t =sala-test-own5 2>/dev/null && [ "$(rowq sala-test-own5 id)" = "$R5" ] && ok "nothing was killed: the replacing session is alive and the row still stands" || bad "own5 after the stuck run: session $(tmux has-session -t =sala-test-own5 2>&1) row '$(rowq sala-test-own5 id)'"
! grep -q "salamander retire" "$HOME/run.out" && ok "the runner never started the retire" || bad "the retire started: $(<"$HOME/run.out")"
tmux kill-session -t =sala-test-own5
out=$(spawn sala-test-own6 "$(uuid 61)" "$PO"); R6=$(rowq sala-test-own6 id)
enq_as "$PO" retire sala-test-own6 --from sala-test-owner; ID6=$ID
sed -i 's/^ownrow=.*/ownrow=not-the-row/' "$OPS/$ID6.op"
rc=$(runop "$ID6")
[ "$(dval "$ID6" state)" = stuck ] && has "$(dval "$ID6" result)" "now is not the one the operation was queued for" && tmux has-session -t =sala-test-own6 2>/dev/null && ok "the row under the name is not the one stored in the marker: stuck, nothing killed" || bad "row mismatch: rc=$rc marker: $(cat "$OPS/done/$ID6.op" "$OPS/$ID6.op" 2>/dev/null | tail -8)"
out=$(spawn sala-test-own7 "$(uuid 71)" "$PO")
enq_as "$PO" retire sala-test-own7 --from sala-test-owner; ID7=$ID
sed -i '/^ownrow=/d' "$OPS/$ID7.op"
rc=$(runop "$ID7")
[ "$(dval "$ID7" state)" = stuck ] && has "$(dval "$ID7" result)" "not a throwaway retire that still passes its checks with its row id" && tmux has-session -t =sala-test-own7 2>/dev/null && ok "a no-words marker without its row id: stuck, nothing killed" || bad "no ownrow: rc=$rc marker: $(cat "$OPS/done/$ID7.op" "$OPS/$ID7.op" 2>/dev/null | tail -8)"
out=$(spawn sala-test-own8 "$(uuid 81)" "$PO")
enq_as "$PO" retire sala-test-own8 --from sala-test-owner; ID8=$ID
rc=$(runop "$ID8")
[ "$(dval "$ID8" state)" = done ] && ! tmux has-session -t =sala-test-own8 2>/dev/null && ok "control: the untouched throwaway is retired by the run (state done, session gone)" || bad "control run: rc=$rc session $(tmux has-session -t =sala-test-own8 2>&1) marker: $(cat "$OPS/done/$ID8.op" "$OPS/$ID8.op" 2>/dev/null | tail -8) log: $(tail -5 "$HOME/run.out")"
dropall

echo "== a failed re-check never starts the claude -p helper, and a child that exits mid-read does not refuse (the High finding of round 3)"
# SALA_OP_STUCK is on for these runs; SALA_OP_CLAUDE is a stub that records that it was started (no suite calls the API)
cat > "$HOME/stub-helper" <<'EOF'
#!/bin/bash
echo "started: $*" >> "$HOME/helper.called"
echo "SALA-OP: stuck the stub did nothing"
EOF
chmod +x "$HOME/stub-helper"; rm -f "$HOME/helper.called"
out=$(spawn sala-test-own9 "$(uuid 91)" "$PO"); R9=$(rowq sala-test-own9 id)
enq_as "$PO" retire sala-test-own9 --from sala-test-owner; ID9=$ID
sed -i 's/^ownrow=.*/ownrow=not-the-row/' "$OPS/$ID9.op"
rc=$(SALA_OP_STUCK=on SALA_OP_CLAUDE="$HOME/stub-helper" runop "$ID9")
[ "$(dval "$ID9" state)" = stuck ] && has "$(dval "$ID9" result)" "nothing was ended" && [ -z "$(dval "$ID9" helper)" ] && [ ! -e "$HOME/helper.called" ] && ! grep -q "claude -p" "$HOME/run.out" \
    && tmux has-session -t =sala-test-own9 2>/dev/null && ok "a no-words re-check mismatch with the helper switched on: stuck, no claude -p started (no helper= on the marker), nothing killed" \
    || bad "mismatch with helper on: rc=$rc called=$(cat "$HOME/helper.called" 2>/dev/null) marker: $(cat "$OPS/done/$ID9.op" 2>/dev/null | tail -8) log: $(tail -4 "$HOME/run.out")"
out=$(spawn sala-test-own10 "$(uuid 92)" "$PO")
enq_as "$PO" retire sala-test-own10 --from sala-test-owner; ID10=$ID
sed -i '/^ownrow=/d' "$OPS/$ID10.op"
rc=$(SALA_OP_STUCK=on SALA_OP_CLAUDE="$HOME/stub-helper" runop "$ID10")
[ "$(dval "$ID10" state)" = stuck ] && [ -z "$(dval "$ID10" helper)" ] && [ ! -e "$HOME/helper.called" ] && tmux has-session -t =sala-test-own10 2>/dev/null && ok "a no-words marker without its row id, helper on: stuck, no claude -p" || bad "no ownrow, helper on: rc=$rc marker: $(cat "$OPS/done/$ID10.op" 2>/dev/null | tail -8)"
# control: an operation queued WITH words that goes stuck for another reason still gets its helper (the attempt is recorded as helper= on the marker)
out=$(spawn sala-test-own11 "$(uuid 93)" "$PO")
enq_as "" retire sala-test-own11 --from sala-test-owner --words "Rowan asked for it"; ID11=$ID
[ -n "$ID11" ] && sed -i '/^arg=/d' "$OPS/$ID11.op"
rc=$(SALA_OP_STUCK=on SALA_OP_CLAUDE="$HOME/stub-helper" runop "$ID11")
[ -n "$ID11" ] && [ -n "$(dval "$ID11" helper)" ] && ok "control: the same helper setting still gives an operation with words its one claude -p (helper= recorded)" || bad "control: id=$ID11 rc=$rc marker: $(cat "$OPS/done/$ID11.op" 2>/dev/null | tail -8) log: $(tail -4 "$HOME/run.out")"
tmux kill-session -t =sala-test-own11 2>/dev/null; dropall
# a short-lived child of the throwaway's pane, gone (a zombie, whose environment reads empty) between the listing and the read, is skipped
out=$(spawn sala-test-own12 "$(uuid 94)" "$PO"); R12=$(rowq sala-test-own12 id)
W=$(tmux new-window -d -P -F '#{window_id}' -t =sala-test-own12: "env SALA_SESSION_ID=$R12 bash -c 'sleep 1 & exec sleep 3144'")
zombie_child() { local p; p=$(pgrep -f 'sleep [3]144' | head -1); [ -n "$p" ] && ps -o stat= --ppid "$p" 2>/dev/null | grep -q Z; }
waitfor "zombie_child" 30 || bad "the zombie child did not appear"
enq_as "$PO" retire sala-test-own12 --from sala-test-owner
[ "$RC" = 0 ] && [ "$(queued)" = 1 ] && ok "a child that exited (a zombie with an empty environment) is skipped: the retire queues" || bad "zombie child: rc=$RC queued=$(queued) — $OUT"
tmux kill-window -t "$W"; dropall

echo "== a throwaway with no live spawner is ended by any session (no words needed)"
enq_as "$PO" retire sala-test-nospawn --from sala-test-owner
[ "$RC" = 0 ] && [ -n "$ID" ] && [ "$(mval "$ID" nowords)" = "$NW_ANY" ] && [ -z "$(mval "$ID" words)" ] && [ -n "$(mval "$ID" ownrow)" ] && ok "a row with no spawner and a throwaway name (*-test-*), asked by owner: queued, note '$NW_ANY', row id stored" || bad "nospawn from owner: rc=$RC — $OUT"
dropall
enq_as "$PX" retire sala-test-nospawn --from sala-test-other
[ "$RC" = 0 ] && [ -n "$ID" ] && [ "$(mval "$ID" nowords)" = "$NW_ANY" ] && ok "the same asked by another session: queued" || bad "nospawn from other: rc=$RC — $OUT"
dropall
callin sala-test-human env TMUX_PANE="$PANE_O" "$SALA" op retire sala-test-nospawn --from sala-test-owner
[ "$RC" != 0 ] && [ "$(queued)" = 0 ] && has "$OUT" "process ancestry" && ok "no caller in a Claude session's pane, still refused for a no-spawner throwaway" || { bad "human, nospawn: rc=$RC queued=$(queued) — $OUT"; dropall; }
eval "$(sed -n '/^op_throwaway_name()/,/^}/p' "$ROOT/lib/op.sh")"
names_ok=1
for n in scratch-20300101-fern sala-check-oak01 x-test-y a-probe-b sala-test-nospawn; do op_throwaway_name "$n" || { names_ok=0; bad "op_throwaway_name refuses $n"; }; done
for n in sala-plain-nospawn demo-builder scratchy testing-x checkpoint-main sala-test probe-x; do op_throwaway_name "$n" && { names_ok=0; bad "op_throwaway_name takes $n"; }; done
[ "$names_ok" = 1 ] && ok "the throwaway names: scratch-*, *-check-*, *-test-*, *-probe-* are taken; a plain name, an agent's name and near misses are not"
driver_up sala-test-gone
out=$(spawn sala-test-orph2 "$(uuid 102)" sala-test-gone); out2=$(spawn sala-plain-orph "$(uuid 103)" sala-test-gone)
[ "$(rowq sala-test-orph2 spawned_by)" = sala-test-gone ] && [ "$(rowq sala-plain-orph spawned_by)" = sala-test-gone ] && ok "two throwaways started by a session (sala-test-gone) that is then closed" || bad "orph rows: '$(rowq sala-test-orph2 spawned_by)' '$(rowq sala-plain-orph spawned_by)' $out $out2"
enq_as "$PO" retire sala-test-orph2 --from sala-test-owner
[ "$RC" != 0 ] && [ "$(queued)" = 0 ] && has "$OUT" "was started by 'sala-test-gone', who is still live" && ok "while its spawner is live: only the spawner (or the master) may" || { bad "orph while spawner live: rc=$RC queued=$(queued) — $OUT"; dropall; }
tmux kill-session -t =sala-test-gone; waitfor "! tmux has-session -t =sala-test-gone 2>/dev/null" 20
enq_as "$PO" retire sala-test-orph2 --from sala-test-owner
[ "$RC" = 0 ] && [ -n "$ID" ] && [ "$(mval "$ID" nowords)" = "$NW_ANY" ] && ok "the spawner gone: any session may (note '$NW_ANY')" || bad "orph, spawner gone: rc=$RC — $OUT"
dropall
refuse "a dead spawner but a name that is no throwaway's" "who is no longer live, but its name is not a throwaway's" "$PO" retire sala-plain-orph --from sala-test-owner

echo "== the master ends any throwaway; nobody ends a project agent, a side session, a listed agent, a name that is no throwaway's"
SALA_MASTER=sala-test-other enq_as "$PX" retire sala-test-own2 --from sala-test-other
[ "$RC" = 0 ] && [ -n "$ID" ] && [ "$(mval "$ID" nowords)" = "$NW_MASTER" ] && ok "the master (other) ends owner's throwaway, whose spawner is live: queued, note '$NW_MASTER'" || bad "master: rc=$RC — $OUT"
dropall
SALA_MASTER=sala-test-other enq_as "$PX" retire sala-test-proj --from sala-test-other
[ "$RC" != 0 ] && [ "$(queued)" = 0 ] && has "$OUT" "is a project agent, not a throwaway" && ok "the master still cannot end a project agent with no words" || { bad "master, project: rc=$RC queued=$(queued) — $OUT"; dropall; }
SALA_MASTER=sala-test-other enq_as "$PX" retire sala-test-sidey --from sala-test-other
[ "$RC" != 0 ] && [ "$(queued)" = 0 ] && has "$OUT" "is a side session" && ok "nor a side session" || { bad "master, side: rc=$RC queued=$(queued) — $OUT"; dropall; }
SALA_MASTER=sala-test-other enq_as "$PO" retire sala-test-other --from sala-test-owner
[ "$RC" != 0 ] && [ "$(queued)" = 0 ] && has "$OUT" "is the master session" && ok "nor the master itself" || { bad "retire the master: rc=$RC queued=$(queued) — $OUT"; dropall; }
out=$(spawn sala-test-projnos "$(uuid 104)"); sessions_set sala-test-projnos project=projects/test role=front
refuse "a no-spawner row with a project and a throwaway name (the name alone is never enough)" "is a project agent, not a throwaway" "$PO" retire sala-test-projnos --from sala-test-owner
out=$(spawn sala-test-sidenos "$(uuid 105)"); sessions_set sala-test-sidenos side=1
refuse "a no-spawner side session with a throwaway name" "is a side session" "$PO" retire sala-test-sidenos --from sala-test-owner
out=$(spawn sala-test-mapped "$(uuid 106)")
record_set fresh   # (the base record again: it lists sala-test-mapped on projects/test)
refuse "a row with no project that is on a project's agents map (stackshot's record)" "is on a project's agents map" "$PO" retire sala-test-mapped --from sala-test-owner
enq_as "$PO" retire sala-test-nospawn --from sala-test-owner
[ "$RC" = 0 ] && [ -n "$ID" ] && ok "with the record present, a name it does not list is still ended" || bad "record present, unlisted name: rc=$RC — $OUT"
dropall

echo "== a bypass flag, --keep-web and --id are never taken with no words (an owner's call, not a throwaway's)"
for fl in --busy --skip-writeup --self --leave-items --keep-web --force; do
    enq_as "$PO" retire sala-test-own1 --from sala-test-owner "$fl"
    if [ "$fl" = --force ]; then want="retire has no --force any more"; else want="takes no bypass flag and no --id"; fi
    [ "$RC" != 0 ] && [ "$(queued)" = 0 ] && has "$OUT" "$want" && ok "own throwaway, $fl, no words: refused at queue time, nothing queued, the message says what to change" || { bad "$fl no words: rc=$RC queued=$(queued) — $OUT"; dropall; }
    enq_as "$PO" retire "$fl" sala-test-own1 --from sala-test-owner   # the flag before the name
    [ "$RC" != 0 ] && [ "$(queued)" = 0 ] && ok "the same with $fl before the name: refused" || { bad "$fl first: rc=$RC queued=$(queued) — $OUT"; dropall; }
done
enq_as "$PO" retire sala-test-own1 --from sala-test-owner --busy --words "Rowan said force it"
[ "$RC" = 0 ] && [ -n "$ID" ] && [ "$(mval "$ID" words)" = "Rowan said force it" ] && [ -z "$(mval "$ID" nowords)" ] && ok "with --words, --busy queues as before (words kept, no nowords note)" || bad "busy with words: rc=$RC — $OUT"
dropall
enq_as "$PO" retire --id 0a0000aa-0000 --from sala-test-owner
[ "$RC" != 0 ] && [ "$(queued)" = 0 ] && has "$OUT" "takes no bypass flag and no --id" && ok "--id with no words: refused at queue time, nothing queued" || { bad "--id no words: rc=$RC queued=$(queued) — $OUT"; dropall; }
enq_as "$PO" retire sala-test-own1 --from sala-test-owner --force --words "Rowan said force it"
[ "$RC" != 0 ] && [ "$(queued)" = 0 ] && has "$OUT" "retire has no --force any more" && has "$OUT" "--busy" && has "$OUT" "--skip-writeup" && ok "--force is refused at queue time even with words, the message names --busy and --skip-writeup" || { bad "--force with words: rc=$RC queued=$(queued) — $OUT"; dropall; }
dropall
out=$(spawn sala-test-flag1 "$(uuid 131)" "$PO")
enq_as "$PO" retire sala-test-flag1 --from sala-test-owner; IDF=$ID
[ "$RC" = 0 ] && [ -n "$IDF" ] && sed -i '/^arg=sala-test-flag1$/a arg=--busy' "$OPS/$IDF.op"   # a marker edited by hand after queueing: the runner asks again
rm -f "$HOME/helper.called"   # (an earlier control in this file started the stub on purpose)
rc=$(SALA_OP_STUCK=on SALA_OP_CLAUDE="$HOME/stub-helper" runop "$IDF")
[ "$(dval "$IDF" state)" = stuck ] && has "$(dval "$IDF" result)" "takes no bypass flag and no --id" && has "$(dval "$IDF" result)" "nothing was ended" && [ -z "$(dval "$IDF" helper)" ] && [ ! -e "$HOME/helper.called" ] && tmux has-session -t =sala-test-flag1 2>/dev/null \
    && ok "a no-words marker with --busy added by hand: the runner goes stuck, nothing ended, no claude -p helper (rc=$rc)" || bad "runner --busy: rc=$rc id=$IDF marker: $(cat "$OPS/done/$IDF.op" "$OPS/$IDF.op" 2>/dev/null | tail -8) log: $(tail -4 "$HOME/run.out")"
tmux kill-session -t =sala-test-flag1 2>/dev/null; dropall

echo "== the agents-map check fails closed for the master and any-session doors (a review finding: a record that cannot answer is a refusal)"
for st in stale missing garbage; do
    record_set "$st"
    refuse "any session, a throwaway with no spawner, record $st" "could not confirm that 'sala-test-nospawn' is unlisted" "$PO" retire sala-test-nospawn --from sala-test-owner
    SALA_MASTER=sala-test-other refuse "the master, owner's throwaway (spawner live), record $st" "could not confirm that 'sala-test-own2' is unlisted" "$PX" retire sala-test-own2 --from sala-test-other
    enq_as "$PO" retire sala-test-own1 --from sala-test-owner
    [ "$RC" = 0 ] && [ -n "$ID" ] && [ "$(mval "$ID" nowords)" = "$NOWORDS" ] && ok "the spawner's own throwaway, record $st: still queued (its registry row is the proof)" || bad "spawner, record $st: rc=$RC — $OUT"
    dropall
done
record_set stale
PG_UNL=$(stub_pages unl 3 "not on the agents map of projects/x")
PG_NOP=$(stub_pages nop 0 "no project page for this name: nothing to check")
PG_LST=$(stub_pages lst 0 "listed on projects/x: a builder")
PG_CNT=$(stub_pages cnt 2 "cannot tell: no brain mirror")
SALA_AGENT_CHECK_SCRIPT=$PG_UNL enq_as "$PO" retire sala-test-nospawn --from sala-test-owner
[ "$RC" = 0 ] && [ -n "$ID" ] && [ "$(mval "$ID" nowords)" = "$NW_ANY" ] && ok "stale record, pages.py says the name is not on its page's agents map (exit 3): queued (SALA_AGENT_CHECK=off does not switch this check off)" || bad "pages.py unlisted: rc=$RC — $OUT"
dropall
SALA_AGENT_CHECK_SCRIPT=$PG_NOP enq_as "$PO" retire sala-test-nospawn --from sala-test-owner
[ "$RC" = 0 ] && [ -n "$ID" ] && ok "stale record, pages.py says there is no project page for the name: queued" || bad "pages.py no page: rc=$RC — $OUT"
dropall
SALA_AGENT_CHECK_SCRIPT=$PG_UNL SALA_MASTER=sala-test-other enq_as "$PX" retire sala-test-own2 --from sala-test-other
[ "$RC" = 0 ] && [ -n "$ID" ] && [ "$(mval "$ID" nowords)" = "$NW_MASTER" ] && ok "stale record, the master's door with pages.py's unlisted answer: queued" || bad "pages.py unlisted, master: rc=$RC — $OUT"
dropall
SALA_AGENT_CHECK_SCRIPT=$PG_LST refuse "stale record, pages.py lists the name on a page" "is on a project's agents map" "$PO" retire sala-test-nospawn --from sala-test-owner
SALA_AGENT_CHECK_SCRIPT=$PG_CNT refuse "stale record, pages.py cannot tell (exit 2)" "pages.py agent-listed exited 2: cannot tell: no brain mirror" "$PO" retire sala-test-nospawn --from sala-test-owner
record_set fresh
SALA_AGENT_CHECK_SCRIPT=$PG_UNL refuse "a fresh record that lists the name wins over pages.py's unlisted" "is on a project's agents map" "$PO" retire sala-test-mapped --from sala-test-owner

echo "== the master ends a throwaway's name, or a row it started; not any row (a review finding)"
out=$(spawn sala-plain-own "$(uuid 121)" "$PO"); out2=$(spawn sala-plain-mastown "$(uuid 122)" "$PX")
[ "$(rowq sala-plain-own spawned_by)" = sala-test-owner ] && [ "$(rowq sala-plain-mastown spawned_by)" = sala-test-other ] && ok "two rows with a plain name: one owner started, one the master (other) started" || bad "plain rows: '$(rowq sala-plain-own spawned_by)' '$(rowq sala-plain-mastown spawned_by)' $out $out2"
SALA_MASTER=sala-test-other refuse "the master, a row owner started under a name that is no throwaway's" "was not started by the master and its name is not a throwaway's" "$PX" retire sala-plain-own --from sala-test-other
SALA_MASTER=sala-test-other enq_as "$PX" retire sala-plain-mastown --from sala-test-other
[ "$RC" = 0 ] && [ -n "$ID" ] && [ "$(mval "$ID" nowords)" = "$NOWORDS" ] && ok "the master, a plain-named row it started itself: queued by the spawner door (note '$NOWORDS')" || bad "master, own plain row: rc=$RC — $OUT"
dropall

echo "== a pane with no row id is bound by its name alone, so the name must be a throwaway's and a fresh answer must say unlisted (a review finding)"
idless_pane() {  # <tmux session name> <uuid n> → a fake claude with no SALA_SESSION_ID (a pane from before row ids, or a victim) under that tmux session name
    tmux set-environment -g FAKE_SESSION_ID "$(uuid "$2")"; tmux set-environment -g FAKE_NAME "$1"
    tmux new-session -d -s "$1" "env -u SALA_SESSION_ID $HOME/.local/bin/claude"
    fake_up "$1" || bad "the id-less fake claude '$1' did not come up"
}
out=$(spawn sala-plain-dead "$(uuid 141)" "$PO"); tmux kill-session -t =sala-plain-dead; waitfor "! tmux has-session -t =sala-plain-dead 2>/dev/null" 20
idless_pane sala-test-victim3 143; tmux rename-session -t =sala-test-victim3 sala-plain-dead
refuse "a victim pane with no row id renamed onto a dead plain-named row owner started (the spawner door)" "carries no row id on any process (a pane from before ids) and its name is not a throwaway's" "$PO" retire sala-plain-dead --from sala-test-owner
tmux kill-session -t =sala-plain-dead 2>/dev/null
out=$(spawn sala-test-dead2 "$(uuid 142)" "$PO"); tmux kill-session -t =sala-test-dead2; waitfor "! tmux has-session -t =sala-test-dead2 2>/dev/null" 20
idless_pane sala-test-victim4 144; tmux rename-session -t =sala-test-victim4 sala-test-dead2
for st in stale missing; do
    record_set "$st"
    refuse "a pane with no row id under a throwaway name, spawner door, record $st" "could not confirm that 'sala-test-dead2' is unlisted" "$PO" retire sala-test-dead2 --from sala-test-owner
done
record_set fresh
enq_as "$PO" retire sala-test-dead2 --from sala-test-owner
[ "$RC" = 0 ] && [ -n "$ID" ] && ok "a pane with no row id under a throwaway name and a fresh unlisted answer: queued (by design all there is to bind it is the name)" || bad "id-less, fresh record: rc=$RC — $OUT"
dropall
tmux kill-session -t =sala-test-dead2 2>/dev/null

echo "== an old row: a pane from before row ids is bound by its name when it is a Claude Code process; a renamed session never is"
out=$(spawn sala-test-old "$(uuid 111)"); ROLD=$(rowq sala-test-old id)
tmux kill-session -t =sala-test-old; waitfor "! tmux has-session -t =sala-test-old 2>/dev/null" 20
tmux set-environment -g FAKE_SESSION_ID "$(uuid 111)"; tmux set-environment -g FAKE_NAME sala-test-old
tmux new-session -d -s sala-test-old "env -u SALA_SESSION_ID $HOME/.local/bin/claude"   # the fake claude of a pane started before row ids: no SALA_SESSION_ID
fake_up sala-test-old || bad "the id-less fake claude did not come up"
enq_as "$PO" retire sala-test-old --from sala-test-owner
[ "$RC" = 0 ] && [ -n "$ID" ] && [ "$(mval "$ID" nowords)" = "$NW_ANY" ] && [ "$(mval "$ID" ownrow)" = "$ROLD" ] && ok "a Claude pane under the name that carries no row id: queued by name binding (note '$NW_ANY')" || bad "old row: rc=$RC — $OUT"
IDOLD=$ID
rc=$(runop "$IDOLD")
[ "$(dval "$IDOLD" state)" = done ] && ! tmux has-session -t =sala-test-old 2>/dev/null && ok "and the runner's second check passes it: state done, session gone" || bad "old row run: rc=$rc session $(tmux has-session -t =sala-test-old 2>&1) marker: $(cat "$OPS/done/$IDOLD.op" "$OPS/$IDOLD.op" 2>/dev/null | tail -8) log: $(tail -5 "$HOME/run.out")"
dropall
out=$(spawn sala-test-ghr "$(uuid 112)"); tmux kill-session -t =sala-test-ghr; waitfor "! tmux has-session -t =sala-test-ghr 2>/dev/null" 20
out=$(spawn sala-test-victim2 "$(uuid 113)")
tmux rename-session -t =sala-test-victim2 sala-test-ghr
enq_as "$PO" retire sala-test-ghr --from sala-test-owner
[ "$RC" != 0 ] && [ "$(queued)" = 0 ] && has "$OUT" "is not the throwaway on that registry row" && ok "a session renamed to a no-spawner throwaway's name (it carries another row's id): refused" || { bad "renamed, no spawner: rc=$RC queued=$(queued) — $OUT"; dropall; }
tmux kill-session -t =sala-test-ghr 2>/dev/null

echo "== the runner passes a no-spawner throwaway and the note stays on the archived marker"
out=$(spawn sala-test-anyrun "$(uuid 114)")
enq_as "$PO" retire sala-test-anyrun --from sala-test-owner; IDA=$ID
rc=$(runop "$IDA")
[ "$(dval "$IDA" state)" = done ] && [ "$(dval "$IDA" nowords)" = "$NW_ANY" ] && ! tmux has-session -t =sala-test-anyrun 2>/dev/null && ok "queued by owner, run: done, session gone, the archived marker keeps '$NW_ANY'" || bad "anyrun: rc=$rc marker: $(cat "$OPS/done/$IDA.op" "$OPS/$IDA.op" 2>/dev/null | tail -8) log: $(tail -5 "$HOME/run.out")"
dropall

echo "== the throwaway tag (tag only): a bare spawn writes it, any session retires a tagged row, an untagged one keeps the earlier rules"
tag_raw() {  # <name> → the tag written straight onto the live row of that name, whatever else the row has (a row that gained a project or a role AFTER it was tagged)
    python3 - "$REG" "$1" <<'PY'
import json, sys
f, name = sys.argv[1:3]
d = json.load(open(f))
for r in d["sessions"].values():
    if r["name"] == name and r["state"] == "live": r["throwaway"] = "1"
json.dump(d, open(f, "w"))
PY
}
TAGGED=1 spawn sala-plain-tag1 "$(uuid 201)" "$PO" >/dev/null; TAGGED=1 spawn sala-plain-tag2 "$(uuid 202)" "$PX" >/dev/null; TAGGED=1 spawn sala-plain-tag3 "$(uuid 203)" >/dev/null
[ "$(rowq sala-plain-tag1 throwaway)" = 1 ] && [ "$(rowq sala-plain-tag1 spawned_by)" = sala-test-owner ] && ok "a bare spawn from a Claude session writes throwaway=1 (and spawned_by as before)" || bad "tag1: throwaway='$(rowq sala-plain-tag1 throwaway)' spawned_by='$(rowq sala-plain-tag1 spawned_by)'"
[ "$(rowq sala-plain-tag3 throwaway)" = 1 ] && [ "$(rowq sala-plain-tag3 spawned_by)" = "" ] && ok "a bare spawn from a plain shell writes it too (it has no spawner)" || bad "tag3: throwaway='$(rowq sala-plain-tag3 throwaway)' spawned_by='$(rowq sala-plain-tag3 spawned_by)'"
[ "$(rowq sala-test-byhuman throwaway)" = 1 ] && [ "$(rowq sala-test-spoofed throwaway)" = 1 ] && ok "the raw spawns of the ancestry cases (a person's pane, a Claude pane) carry it" || bad "raw spawns: byhuman='$(rowq sala-test-byhuman throwaway)' spoofed='$(rowq sala-test-spoofed throwaway)'"
[ "$(rowq sala-test-own1 throwaway)" = "" ] && ok "(the other suite rows had the tag taken off: they stand in for rows from before it)" || bad "own1 still tagged: '$(rowq sala-test-own1 throwaway)'"
# a spawn with a project, a role or a side flag never writes it
tmux set-environment -g FAKE_SESSION_ID "$(uuid 221)"; tmux set-environment -g FAKE_NAME sala-plain-kproj
callin "$PO" "$SALA" spawn sala-plain-kproj --cwd "$HOME/work" --project projects/test --role back --mandate "x" --no-confirm; rc=$RC; out=$OUT
if [ "$(rowq sala-plain-kproj id)" = "<none>" ]; then bad "spawn with a project: no row (rc=$rc): $out"
else [ "$(rowq sala-plain-kproj throwaway)" = "" ] && [ "$(rowq sala-plain-kproj project)" = projects/test ] && ok "a spawn with --project and --role never writes the tag (row live, project='$(rowq sala-plain-kproj project)' role='$(rowq sala-plain-kproj role)')" || bad "spawn with a project wrote the tag: '$(rowq sala-plain-kproj throwaway)'"; fi
tmux set-environment -g FAKE_SESSION_ID "$(uuid 222)"; tmux set-environment -g FAKE_NAME sala-test-side-kite01
callin "$PO" "$SALA" spawn sala-test-side-kite01 --cwd "$HOME/work" --side --project projects/test --item board#9001; rc=$RC; out=$OUT
if [ "$(rowq sala-test-side-kite01 id)" = "<none>" ]; then bad "spawn --side: no row (rc=$rc): $out"
else [ "$(rowq sala-test-side-kite01 throwaway)" = "" ] && [ "$(rowq sala-test-side-kite01 side)" = 1 ] && ok "a spawn with --side never writes the tag (row live, side='$(rowq sala-test-side-kite01 side)')" || bad "spawn --side wrote the tag: '$(rowq sala-test-side-kite01 throwaway)'"; fi
# a tagged row that is given a project, a role or a side mark loses the tag (sessions set, sessions tag)
TAGGED=1 spawn sala-plain-tagp "$(uuid 211)" >/dev/null; TAGGED=1 spawn sala-plain-tagt "$(uuid 212)" >/dev/null; TAGGED=1 spawn sala-plain-tags "$(uuid 213)" >/dev/null
sessions_set sala-plain-tagp project=projects/test role=back; sessions_py tag sala-plain-tagt --project projects/test >/dev/null 2>&1; sessions_set sala-plain-tags side=1
[ "$(rowq sala-plain-tagp throwaway)" = "" ] && [ "$(rowq sala-plain-tagt throwaway)" = "" ] && [ "$(rowq sala-plain-tags throwaway)" = "" ] && ok "set project/role, tag --project and set side each clear the tag" || bad "tag not cleared: set='$(rowq sala-plain-tagp throwaway)' tag='$(rowq sala-plain-tagt throwaway)' side='$(rowq sala-plain-tags throwaway)'"
sessions_set sala-plain-tag3 lane=subscription-1; [ "$(rowq sala-plain-tag3 throwaway)" = 1 ] && ok "an unrelated field set leaves the tag alone" || bad "tag3 lost the tag on a lane set"
# any live session retires a tagged row: the spawner alive, any name, no spawner at all
enq_as "$PX" retire sala-plain-tag1 --from sala-test-other
[ "$RC" = 0 ] && [ -n "$ID" ] && [ "$(mval "$ID" nowords)" = "$NW_TAG" ] && [ -z "$(mval "$ID" words)" ] && [ -n "$(mval "$ID" ownrow)" ] && ok "an unrelated live session (other) retires owner's tagged throwaway while owner is live, under a name no pattern covers: queued, note '$NW_TAG', row id stored" || bad "tagged by other: rc=$RC — $OUT"
dropall
enq_as "$PO" retire sala-plain-tag2 --from sala-test-owner
[ "$RC" = 0 ] && [ -n "$ID" ] && [ "$(mval "$ID" nowords)" = "$NW_TAG" ] && ok "and the other way round (owner retires other's, other is live)" || bad "tagged by owner: rc=$RC — $OUT"
dropall
enq_as "$PO" retire sala-plain-tag3 --from sala-test-owner
[ "$RC" = 0 ] && [ -n "$ID" ] && [ "$(mval "$ID" nowords)" = "$NW_TAG" ] && ok "a tagged row from a plain shell (no spawner): queued by any session" || bad "tagged, no spawner: rc=$RC — $OUT"
dropall
enq_as "$PO" retire sala-plain-tag1 --from sala-test-owner
[ "$RC" = 0 ] && [ -n "$ID" ] && [ "$(mval "$ID" nowords)" = "$NOWORDS" ] && ok "its own spawner still ends it under the spawner rule (note '$NOWORDS')" || bad "tagged, spawner: rc=$RC — $OUT"
dropall
SALA_MASTER=sala-test-other enq_as "$PX" retire sala-plain-tag1 --from sala-test-other
[ "$RC" = 0 ] && [ -n "$ID" ] && [ "$(mval "$ID" nowords)" = "$NW_TAG" ] && ok "the master ends a tagged row of any name (not only a throwaway's name, as for an untagged one)" || bad "tagged by master: rc=$RC — $OUT"
dropall
# still refused, tag or not
refuse_tag() {  # <why> <fragment> <pane> <op args…>: a refusal of a tagged row (the message need not name the old rule)
    local why=$1 frag=$2 p=$3; shift 3
    enq_as "$p" "$@"
    if [ "$RC" != 0 ] && [ "$(queued)" = 0 ] && has "$OUT" "refused here: " && has "$OUT" "$frag"; then ok "refused: $why"; else bad "$why: rc=$RC queued=$(queued) — $OUT"; dropall; fi
}
tag_raw sala-test-owner
refuse_tag "a tagged row asked to end itself" "is the asking session itself" "$PO" retire sala-test-owner --from sala-test-owner
sessions_set sala-test-owner throwaway=
TAGGED=1 spawn sala-plain-tagm "$(uuid 214)" >/dev/null
SALA_MASTER=sala-plain-tagm refuse_tag "a tagged row that is the master" "is the master session" "$PO" retire sala-plain-tagm --from sala-test-owner
tag_raw sala-test-proj; tag_raw sala-test-sidey; tag_raw sala-test-mapped
[ "$(rowq sala-test-proj throwaway)" = 1 ] && [ "$(rowq sala-test-proj project)" = projects/test ] && ok "(a row that has a project AND the tag, written straight onto it: it must not count)" || bad "tag_raw proj"
refuse_tag "a tagged row that has a project and a role (the tag does not count)" "is a project agent, not a throwaway" "$PX" retire sala-test-proj --from sala-test-other
refuse_tag "a tagged row that is a side session" "is a side session" "$PX" retire sala-test-sidey --from sala-test-other
refuse_tag "a tagged row on a project's agents map (the record lists it)" "is on a project's agents map" "$PX" retire sala-test-mapped --from sala-test-other
record_set stale
refuse_tag "a tagged row when the project record is stale and pages.py is not there to ask (fails closed)" "could not confirm that 'sala-plain-tag2' is unlisted" "$PO" retire sala-plain-tag2 --from sala-test-owner
record_set fresh
enq_as "$PO" retire sala-plain-tag2 --from sala-test-owner --busy
[ "$RC" != 0 ] && [ "$(queued)" = 0 ] && has "$OUT" "takes no bypass flag and no --id" && ok "a tagged row still takes no bypass flag and no --keep-web with no words" || { bad "tagged --busy: rc=$RC — $OUT"; dropall; }
# an untagged row keeps the earlier rules, untouched by the tag
[ "$(rowq sala-test-theirs throwaway)" = "" ] && [ "$(rowq sala-plain-nospawn throwaway)" = "" ] || bad "legacy rows carry a tag"
refuse "an untagged row whose spawner is live (as before the tag)" "was started by 'sala-test-other', who is still live" "$PO" retire sala-test-theirs --from sala-test-owner
refuse "an untagged row with no spawner under a name that is no throwaway's (as before the tag)" "has no spawner on its registry row and its name is not a throwaway's" "$PO" retire sala-plain-nospawn --from sala-test-owner
enq_as "$PO" retire sala-test-nospawn --from sala-test-owner
[ "$RC" = 0 ] && [ -n "$ID" ] && [ "$(mval "$ID" nowords)" = "$NW_ANY" ] && ok "an untagged row with no spawner and a throwaway's name: any session, note '$NW_ANY' (the name-pattern rule is kept for it)" || bad "legacy name rule: rc=$RC — $OUT"
dropall
# the runner: a tagged row is ended (retire's own idle check applies; a no-words retire has no --busy)
enq_as "$PO" retire sala-plain-tag2 --from sala-test-owner; IDT=$ID
rc=$(runop "$IDT")
[ "$(dval "$IDT" state)" = done ] && [ "$(dval "$IDT" nowords)" = "$NW_TAG" ] && ! tmux has-session -t =sala-plain-tag2 2>/dev/null && ok "queued by an unrelated session and run: done, session gone, the archived marker keeps '$NW_TAG'" || bad "tag run: rc=$rc marker: $(cat "$OPS/done/$IDT.op" "$OPS/$IDT.op" 2>/dev/null | tail -8) log: $(tail -5 "$HOME/run.out")"
dropall

echo "== the reason door: a revive of live sessions with --item or --why is queued with no words (the words policy; every other verb keeps the refusal)"
RA=sala-test-theirs; RB=sala-test-own2; RC_=sala-plain-nospawn   # three live rows (and tmux sessions) to revive; owner and other ask
nstart() { local n; n=$(grep -c "^start $1" "$FAKE_LOG" 2>/dev/null); echo "${n:-0}"; }   # <uuid> → how many times that fake claude was started
allstarts() { local n; n=$(grep -c "^start " "$FAKE_LOG" 2>/dev/null); echo "${n:-0}"; }
NWI="words: none (board#9007: revive of one session)"
enq_as "$PO" revive --only "$RA" --item board#9007 --from sala-test-owner
[ "$RC" = 0 ] && [ -n "$ID" ] && ok "queued with no words: $(head -1 <<< "$OUT")" || bad "reason door, item: rc=$RC — $OUT"
if [ -n "$ID" ]; then
    [ "$(mval "$ID" verb)" = revive ] && [ "$(awk -F= '$1=="arg"{printf "%s ", $2}' "$OPS/$ID.op")" = "--only $RA " ] && [ -z "$(mval "$ID" words)" ] && [ "$(mval "$ID" nowords)" = "$NWI" ] && [ "$(mval "$ID" item)" = board#9007 ] \
        && [ -z "$(mval "$ID" reason)" ] && [ "$(mval "$ID" ownrow)" = "$(rowq $RA id)" ] && [ -n "$(rowq $RA id)" ] && [ "$(mval "$ID" from)" = sala-test-owner ] \
        && ok "the marker: revive --only $RA, words empty, item=board#9007, ownrow = the row id, nowords='$NWI'" || bad "marker: $(<"$OPS/$ID.op")"
    has "$OUT" "$NWI" && ok "the queued line carries the note" || bad "queued line: $OUT"
    LIST=$("$SALA" op --list 2>&1); STAT=$("$SALA" op --status "$ID" 2>&1)
    has "$LIST" "$NWI" && has "$STAT" "item: board#9007" && has "$STAT" "nowords: $NWI" && ok "op --list shows the note and op --status the item" || bad "list/status: $LIST / $STAT"
    grep -qF -- "$NWI" "$HOME/.claude/salamander-op.log" 2>/dev/null && ok "the op log line says it" || bad "op log: $(tail -3 "$HOME/.claude/salamander-op.log" 2>/dev/null)"
fi
dropall
enq_as "$PO" revive --only "$RA" --why "the pane is alive but does not answer" --from sala-test-owner
[ "$RC" = 0 ] && [ -n "$ID" ] && [ "$(mval "$ID" nowords)" = "words: none (reason: the pane is alive but does not answer)" ] && [ "$(mval "$ID" reason)" = "the pane is alive but does not answer" ] && [ -z "$(mval "$ID" item)" ] && [ -z "$(mval "$ID" why)" ] \
    && ok "--why: queued, the marker keeps reason= (not why=, which is the stuck handler's) and the note shows it" || bad "why: rc=$RC — $OUT / $(cat "$OPS/$ID.op" 2>/dev/null)"
dropall
enq_as "$PX" revive --only "$RA" --only "$RB" --force --item board#9007 --from sala-test-other
[ "$RC" = 0 ] && [ -n "$ID" ] && [ "$(awk -F= '$1=="arg"{printf "%s ", $2}' "$OPS/$ID.op")" = "--only $RA --only $RB --force " ] && [ "$(mval "$ID" nowords)" = "words: none (board#9007: revive of 2 sessions)" ] \
    && [ "$(mvals "$ID" ownrow | paste -sd, -)" = "$(rowq $RA id),$(rowq $RB id)" ] && ok "--force and two --only (asked by another session): queued, one ownrow per session in order, 'revive of 2 sessions'" || bad "two --only: rc=$RC — $OUT / $(cat "$OPS/$ID.op" 2>/dev/null)"
dropall
enq_as "$PO" revive --only "$RA" --item board#9007 --from sala-test-owner --words "Rowan said revive it"
[ "$RC" = 0 ] && [ -n "$ID" ] && [ "$(mval "$ID" words)" = "Rowan said revive it" ] && [ -z "$(mval "$ID" nowords)" ] && [ -z "$(mval "$ID" ownrow)" ] && [ "$(mval "$ID" item)" = board#9007 ] && ok "with --words, --item is only recorded (words kept, no nowords note, no ownrow)" || bad "words + item: rc=$RC — $OUT"
dropall
enq_as "" revive --only "$RA" --why "recorded next to the words" --from t --words "revive it"
[ "$RC" = 0 ] && [ -n "$ID" ] && [ "$(mval "$ID" reason)" = "recorded next to the words" ] && [ -z "$(mval "$ID" nowords)" ] && ok "with --words, --why is recorded too (from a plain shell)" || bad "words + why: rc=$RC — $OUT"
dropall
enq_as "$PO" --plan revive --only "$RA" --item board#9007 --from sala-test-owner
[ "$RC" = 0 ] && has "$OUT" "plan only: nothing queued" && [ "$(queued)" = 0 ] && ok "--plan with --item: the dry run shown, nothing queued" || bad "plan: rc=$RC — $OUT"

echo "== the reason door's refusals: nothing queued, the sentence says what is missing"
rrefuse() {  # <why> <fragment> <expected rc, or "" for any non-zero> <pane> <op args…>
    local why=$1 frag=$2 xrc=$3 p=$4; shift 4
    enq_as "$p" "$@"
    if [ "$RC" != 0 ] && { [ -z "$xrc" ] || [ "$RC" = "$xrc" ]; } && [ "$(queued)" = 0 ] && has "$OUT" "$frag"; then ok "refused: $why"; else bad "$why: rc=$RC queued=$(queued) — $OUT"; dropall; fi
}
rrefuse "no reason at all (the owner's words are named)" "needs a reason: --item board#N" "" "$PO" revive --only "$RA" --from sala-test-owner
rrefuse "the generic refusal names the door too" "The one other: \`op revive --only NAME" "" "$PO" revive --only "$RA" --from sala-test-owner
rrefuse "an item that is not board#N: board#x" "is not a board item id" 2 "$PO" revive --only "$RA" --item board#x --from sala-test-owner
rrefuse "an item that is not board#N: #5" "is not a board item id" 2 "$PO" revive --only "$RA" --item '#5' --from sala-test-owner
rrefuse "an item that is not board#N: 5" "is not a board item id" 2 "$PO" revive --only "$RA" --item 5 --from sala-test-owner
rrefuse "an item with two lines" "is not a board item id" 2 "$PO" revive --only "$RA" --item $'board#9007\nboard#9008' --from sala-test-owner
rrefuse "--item with no value" "--item needs a board item id" 2 "$PO" revive --only "$RA" --from sala-test-owner --item
rrefuse "a why of two words" "three words or more" 2 "$PO" revive --only "$RA" --why "restart it" --from sala-test-owner
rrefuse "an empty why" "--why needs a reason" 2 "$PO" revive --only "$RA" --why "" --from sala-test-owner
rrefuse "a why of two lines" "one line" 2 "$PO" revive --only "$RA" --why $'it is alive\nbut not working' --from sala-test-owner
rrefuse "a why of more than 200 characters" "at most 200 characters" 2 "$PO" revive --only "$RA" --why "$(printf 'word %.0s' $(seq 1 60))" --from sala-test-owner
rrefuse "an item and a why together" "not both" 2 "$PO" revive --only "$RA" --item board#9007 --why "it is alive but idle" --from sala-test-owner
rrefuse "a sweep (no --only) with an item" "no --words" 1 "$PO" revive --item board#9007 --from sala-test-owner
rrefuse "a sweep with --force and an item" "no --words" 1 "$PO" revive --force --item board#9007 --from sala-test-owner
rrefuse "--rescue is not a revive flag of the queue" "revive takes --only NAME and --force only" 2 "$PO" revive --only "$RA" --rescue --item board#9007 --from sala-test-owner
rrefuse "--lane-default is not either" "revive takes --only NAME and --force only" 2 "$PO" revive --only "$RA" --lane-default --item board#9007 --from sala-test-owner
rrefuse "--item on recycle" "accepted only with revive" 2 "$PO" recycle --item board#9007 --from sala-test-owner --words "recycle"
rrefuse "--item on retire (even with words)" "accepted only with revive" 2 "$PO" retire "$RB" --item board#9007 --from sala-test-owner --words "retire"
rrefuse "--item on lane" "accepted only with revive" 2 "$PO" lane subscription-1 "$RB" --item board#9007 --from sala-test-owner --words "lane"
rrefuse "--item on model" "accepted only with revive" 2 "$PO" model "$RB" opus --item board#9007 --from sala-test-owner --words "model"
rrefuse "--why on retire (no words)" "accepted only with revive" 2 "$PO" retire "$RB" --why "it is not working at all" --from sala-test-owner
rrefuse "--why on close-shell" "accepted only with revive" 2 "$PO" close-shell "$RB" --why "it is not working at all" --from sala-test-owner --words "x"
rrefuse "a name with no row" "has no live registry row under that exact name" "" "$PO" revive --only sala-test-ghost --item board#9007 --from sala-test-owner
rrefuse "the row's id in place of its name" "is not the registry row's own name" "" "$PO" revive --only "$(rowq $RB id)" --item board#9007 --from sala-test-owner
rrefuse "the asking session itself" "is the asking session itself" "" "$PO" revive --only sala-test-owner --item board#9007 --from sala-test-owner
rrefuse "the asking session among several" "is the asking session itself" "" "$PO" revive --only "$RA" --only sala-test-owner --item board#9007 --from sala-test-owner
SALA_MASTER="$RA" rrefuse "the master" "is the master session" "" "$PO" revive --only "$RA" --item board#9007 --from sala-test-owner
SALA_MASTER="$RB" rrefuse "the master among several" "is the master session" "" "$PO" revive --only "$RA" --only "$RB" --item board#9007 --from sala-test-owner
SALA_OP_REASON_FROM="sala-test-other" rrefuse "a sender the allow list does not name (SALA_OP_REASON_FROM)" "may not revive with no words" "" "$PO" revive --only "$RA" --item board#9007 --from sala-test-owner
SALA_OP_REASON_FROM="sala-test-other" enq_as "$PX" revive --only "$RA" --item board#9007 --from sala-test-other
[ "$RC" = 0 ] && [ -n "$ID" ] && ok "and the one it names is queued" || bad "allow list, listed sender: rc=$RC — $OUT"
dropall
# the caller is placed by process ancestry, as for retire's door
OUT=$("$SALA" op revive --only "$RA" --item board#9007 --from sala-test-owner 2>&1); RC=$?
[ "$RC" != 0 ] && [ "$(queued)" = 0 ] && has "$OUT" "process ancestry" && ok "a plain shell with no words: refused (a human there passes --words)" || { bad "plain shell: rc=$RC queued=$(queued) — $OUT"; dropall; }
OUT=$(TMUX_PANE="$PANE_O" "$SALA" op revive --only "$RA" --item board#9007 --from sala-test-owner 2>&1); RC=$?
[ "$RC" != 0 ] && [ "$(queued)" = 0 ] && has "$OUT" "process ancestry" && ok "a plain shell with TMUX_PANE set to owner's pane and --from owner: refused" || { bad "spoofed pane: rc=$RC queued=$(queued) — $OUT"; dropall; }
callin sala-test-other env TMUX_PANE="$PANE_O" "$SALA" op revive --only "$RA" --item board#9007 --from sala-test-owner
[ "$RC" != 0 ] && [ "$(queued)" = 0 ] && has "$OUT" "this call runs in session 'sala-test-other'" && ok "a claude child in other's pane claiming --from owner: refused (placed in other)" || { bad "wrong session: rc=$RC queued=$(queued) — $OUT"; dropall; }
callin sala-test-human env TMUX_PANE="$PANE_O" "$SALA" op revive --only "$RA" --item board#9007 --from sala-test-owner
[ "$RC" != 0 ] && [ "$(queued)" = 0 ] && has "$OUT" "process ancestry" && ok "a person's shell in a pane (no claude above the call): refused" || { bad "human pane: rc=$RC queued=$(queued) — $OUT"; dropall; }
rm -f "$HOME/orph.out"
callin sala-test-owner bash -c '( ( sleep 0.5; "$1" op revive --only "$3" --item board#9007 --from sala-test-owner > "$2" 2>&1; echo "rc=$?" >> "$2" ) & )' _ "$SALA" "$HOME/orph.out" "$RA"
waitfor "grep -q '^rc=' '$HOME/orph.out' 2>/dev/null" 60 || bad "the orphaned call did not end"
OUT=$(<"$HOME/orph.out"); has "$OUT" "rc=1" && [ "$(queued)" = 0 ] && has "$OUT" "process ancestry" && ok "an orphaned call (double fork, adopted by init): refused" || { bad "orphan: $OUT"; dropall; }
rrefuse "--auto in a Claude session (a relayed message is never the owner's words)" "--auto is for markers sala writes itself" "" "$PO" revive --only "$RA" --item board#9007 --from sala-test-owner --auto
rm -f "$HOME/auto.out" "$HOME/auto.anc"
( ( sleep 0.5; p=$BASHPID; anc=""; while [ "$p" -gt 1 ] 2>/dev/null; do anc="$anc $(cat /proc/$p/comm 2>/dev/null)"; p=$(awk '{print $4}' /proc/$p/stat 2>/dev/null); done; echo "$anc" > "$HOME/auto.anc"
    "$SALA" op revive --only "$RA" --item board#9007 --from t --auto > "$HOME/auto.out" 2>&1; echo "rc=$?" >> "$HOME/auto.out" ) & )
waitfor "grep -q '^rc=' '$HOME/auto.out' 2>/dev/null" 60 || bad "the orphaned --auto call did not end"
OUT=$(<"$HOME/auto.out")   # (a suite run from a Claude session's pane may still sit under a claude, where the older --auto refusal is the one that answers)
[ "$(queued)" = 0 ] && { has "$OUT" "carries no --item or --why" || { grep -qw claude "$HOME/auto.anc" && has "$OUT" "--auto is for markers sala writes itself"; }; } && ok "--auto from a plain shell with an item: refused too (the door is not an auto path)" || { bad "auto, shell: queued=$(queued) — $OUT"; dropall; }
# every other verb with no words keeps the plain refusal, and retire's throwaway door is not this door
for v in "recycle" "update" "close-shell $RB" "forget-row sala-test-ghost" "rename $RB sala-test-renamed2" "lane default max" "model $RB opus" "provision"; do
    enq_as "$PO" $v --from sala-test-owner
    if [ "$RC" != 0 ] && [ "$(queued)" = 0 ] && has "$OUT" "no --words" && ! has "$OUT" "refused here: "; then ok "'$v' with no words: still refused, no door named for it"; else bad "'$v' no words: rc=$RC queued=$(queued) — $OUT"; dropall; fi
done
enq_as "$PO" retire "$RB" --from sala-test-owner --item board#9007
[ "$RC" != 0 ] && [ "$(queued)" = 0 ] && has "$OUT" "accepted only with revive" && ok "a retire with an item is refused at shape time, not read as a throwaway retire" || { bad "retire + item: rc=$RC — $OUT"; dropall; }
enq_as "$PO" retire sala-test-theirs --from sala-test-owner
[ "$RC" != 0 ] && [ "$(queued)" = 0 ] && has "$OUT" "was started by 'sala-test-other', who is still live" && ok "retire's throwaway door unchanged: another session's throwaway is still refused" || { bad "retire door: rc=$RC — $OUT"; dropall; }

echo "== the policy table and the stuck helper's rules"
POL=$( . "$ROOT/lib/op.sh"; for c in "recycle" "update" "revive" "revive --force" "revive --only a" "revive --only a --force" "revive --only a --only b --force" "revive --only a --rescue" "revive --only" "retire a" "retire --id x" \
        "close-shell a" "forget-row a" "rename a b" "lane x a" "model a opus" "provision" "spawn a" "reboot" "frob"; do op_words_policy $c; printf '%s=%s;' "${c// /_}" "$OP_POLICY"; done )
EXPECT="recycle=owner;update=owner;revive=owner;revive_--force=owner;revive_--only_a=reason;revive_--only_a_--force=reason;revive_--only_a_--only_b_--force=reason;revive_--only_a_--rescue=owner;revive_--only=owner;retire_a=throwaway;retire_--id_x=throwaway;close-shell_a=owner;forget-row_a=owner;rename_a_b=owner;lane_x_a=owner;model_a_opus=owner;provision=owner;spawn_a=owner;reboot=owner;frob=owner;"
[ "$POL" = "$EXPECT" ] && ok "op_words_policy: revive with --only names (and --force) is reason, retire is throwaway, a sweep, any other flag and every other verb is owner" || bad "policy: $POL"
dropall
enq_as "$PO" revive --only "$RA" --force --item board#9007 --from sala-test-owner; IDB=$ID
BRIEF=$( . "$ROOT/lib/op.sh"; op_brief "$IDB" "it exited 1" )
has "$BRIEF" "revive [--force] --only <those NAMEs>" && has "$BRIEF" "NEVER run \`salamander retire\`" && has "$BRIEF" "that session revives the sessions named" && ok "the helper's brief: for a no-words revive only revive [--force] --only the named sessions, and no retire" || bad "brief: $BRIEF"
dropall

echo "== the runner judges the revive again before it relaunches anything"
S0=$(allstarts); NA0=$(nstart "$(uuid 13)"); NB0=$(nstart "$(uuid 12)")
enq_as "$PO" revive --only "$RA" --force --item board#9007 --from sala-test-owner; IDR=$ID
[ -n "$IDR" ] || bad "control not queued: $OUT"
rc=$(runop "$IDR")
waitfor "[ \"\$(nstart '$(uuid 13)')\" -gt $NA0 ]" 60
[ "$(dval "$IDR" state)" = done ] && [ "$(dval "$IDR" nowords)" = "$NWI" ] && [ "$(nstart "$(uuid 13)")" -gt "$NA0" ] && [ "$(( $(allstarts) - S0 ))" = "$(( $(nstart "$(uuid 13)") - NA0 ))" ] \
    && ok "control: the untouched marker runs 'revive --only $RA --force': done, that one session relaunched and no other (nowords kept on the archived marker)" || bad "control run: rc=$rc starts +$(( $(allstarts) - S0 )) / ${RA} +$(( $(nstart "$(uuid 13)") - NA0 )) marker: $(cat "$OPS/done/$IDR.op" 2>/dev/null | tail -8) log: $(tail -5 "$HOME/run.out")"
fake_up "$RA"
mismatch() {  # <label> <sed script or "" > <env assignment or ""> <fragment of the result> [<fragment 2, default "nothing was ">] → a queued revive of RA, the marker edited, run: stuck, nothing relaunched, no helper
    local label=$1 ed=$2 envv=$3 frag=$4 frag2=${5:-nothing was } s0 id rc2
    enq_as "$PO" revive --only "$RA" --force --item board#9007 --from sala-test-owner; id=$ID
    [ -n "$id" ] || { bad "$label: not queued: $OUT"; return; }
    [ -z "$ed" ] || sed -i "$ed" "$OPS/$id.op"
    s0=$(allstarts); rm -f "$HOME/helper.called"
    rc2=$(env ${envv:+"$envv"} SALA_OP_STUCK=on SALA_OP_CLAUDE="$HOME/stub-helper" "$SALA" op --run "$id" > "$HOME/run.out" 2>&1; echo $?)
    if [ "$(dval "$id" state)" = stuck ] && has "$(dval "$id" result)" "$frag" && has "$(dval "$id" result)" "$frag2" && [ "$(allstarts)" = "$s0" ] && [ -z "$(dval "$id" helper)" ] && [ ! -e "$HOME/helper.called" ] && ! grep -q "running: salamander" "$HOME/run.out"; then
        ok "$label: stuck with the reason, nothing relaunched, no claude -p"
    else bad "$label: rc=$rc2 starts=$(( $(allstarts) - s0 )) marker: $(tail -9 "$OPS/done/$id.op" 2>/dev/null) log: $(tail -4 "$HOME/run.out")"; fi
    dropall
}
mismatch "the row id replaced" 's/^ownrow=.*/ownrow=not-the-row/' "" "now is not the one the operation was queued for"
mismatch "the row id deleted" '/^ownrow=/d' "" "carries 0 registry row id(s)"
mismatch "the item deleted" '/^item=/d' "" "carries no reason"
mismatch "the item malformed" 's/^item=.*/item=board#x/' "" "is not a board item id"
mismatch "an item and a reason together" '/^item=/a reason=it is not working at all' "" "both an item and a reason"
mismatch "a reason of two words" 's/^item=.*/reason=restart it/' "" "three words or more"
mismatch "a second session added to the arguments, no row id for it" "/^arg=--force/a arg=--only"$'\n'"/^arg=--force/a arg=$RB" "" "registry row id(s)"
mismatch "a flag --rescue added (the shape no longer fits)" '/^arg=--force/a arg=--rescue' "" "does not fit the verb's shape" "revive takes"
mismatch "the sweep (the --only removed)" '/^arg=--only/d;/^arg=sala-test-theirs/d' "" "not a throwaway retire that still passes"
mismatch "the sender no longer allowed" "" "SALA_OP_REASON_FROM=sala-test-other" "may no longer revive with no words"
mismatch "the session made the master since" "" "SALA_MASTER=$RA" "is the master session"
mismatch "the sender is the session itself" "s/^from=.*/from=$RA/" "" "is the asking session itself"
mismatch "the marker is a different verb with no words (recycle)" 's/^verb=revive/verb=recycle/;/^arg=/d' "" "not a throwaway retire that still passes"

echo "== the help says it"
HELP=$("$SALA" op --help 2>&1)
has "$HELP" "op revive --only NAME… --item board#N --from YOU" && has "$HELP" "--why" && has "$HELP" "SALA_OP_REASON_FROM" && has "$HELP" "format check only" && ok "op --help describes the reason door (format check only, the allow list)" || bad "op --help (revive): $HELP"
has "$HELP" "throwaway tag" && has "$HELP" "NO words" && ok "op --help describes the exception" || bad "op --help: $HELP"
has "$HELP" "never with a bypass flag, --keep-web or --id" && has "$HELP" "must confirm NAME is on no agents map" && has "$HELP" "the master (NAME a" && ok "and its rules: no bypass flag, --keep-web or --id, the master needs a throwaway's name, the agents-map check fails closed" || bad "op --help rules: $HELP"

[ "$fail" = 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
