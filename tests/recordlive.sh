#!/usr/bin/env bash
# Where sala reads stackshot's project record and roles list from (lib/stackshot_record.py, `record_file_r` in lib/common.sh, docs/stackshot-contracts.md interface 20).
# stackshot is asked FIRST, by its address, through its client (`get state-files` for the record, `get roles` for the list, under a timeout, stdin closed); the file copy
# the puller writes is read ONLY when stackshot cannot be reached, and its age is said (the refusal, the source line, one line in salamander-record.log). A stub client
# (no network, no real stackshot) answers from files this suite writes, or is down, hangs, or answers what sala cannot read. Checked:
#   the shell reader (project_record_agent, project_for_name, retire_project_of, rename_record_plan, record_note) · the Python reader (lib/stackshot_record.py as a command and
#   as bgagents.py uses it) · a live answer beats a file copy that says something else, and a file copy is never read while stackshot answers · stackshot down, hanging, not JSON,
#   with no record to give: the file copy, its age said, the log line (one per five minutes, not one per read) · a stale copy answers nothing and says so · the answer kept for a few
#   seconds (one ask for many reads) and a failed ask kept as long · the one copy a rename reads for both its names · SALA_RECORD_LIVE=off and no client: the file alone, no ask.
# Isolated HOME in a temp folder (locked while the suite runs, removed at the end), no tmux, no process started but bash, python3 and the stub (a `sleep` it starts ends by itself).
# Usage: bash tests/recordlive.sh   (exit 0 = pass; under a minute)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
T=""
trap '[ -n "$T" ] && rm -rf "$T"' EXIT
T=$(mktemp -d "${TMPDIR:-/tmp}/sala-reclive.XXXXXX")
exec 8< "$T"; flock -n 8 2>/dev/null   # systemd-tmpfiles' ageing skips a directory held with flock
export HOME="$T/home"; mkdir -p "$HOME/.claude" "$HOME/.config/salamander" "$HOME/.local/state/stackshot"
unset SALA_STACKSHOT_DIR SALA_STACKSHOT_CLIENT STACKSHOT_CLIENT SALA_RECORD_LIVE SALA_RECORD_LIVE_TIMEOUT SALA_RECORD_PIN
export SALA_RECORD_LIVE_TTL=0 XDG_STATE_HOME="$HOME/.local/state"
FILE_REC="$HOME/.local/state/stackshot/projects.json"; FILE_ROLES="$HOME/.local/state/stackshot/roles.json"
LIVE_REC="$HOME/ss-projects.json"; LIVE_ROLES="$HOME/ss-roles.json"; CALLS="$HOME/ss-calls.txt"; MODE="$HOME/ss-mode"; LOG="$HOME/.claude/salamander-record.log"
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

# the stub stackshot client: `get state-files` gives {"projects": <$LIVE_REC>}, `get roles` gives $LIVE_ROLES; every call is logged with whether stdin was closed;
# $MODE: ok (default) | down (exit 1, "[0] not reached") | hang (sleeps 30 s) | junk (exit 0, not JSON) | norecord (state-files with "projects": null)
cat > "$HOME/fake-ss.py" <<'PY'
import json, os, select, sys, time
home = os.environ["HOME"]; a = sys.argv[1:]
closed = bool(select.select([sys.stdin], [], [], 0)[0])      # stdin at its end (/dev/null) is readable at once; an open, idle pipe is not
open(home + "/ss-calls.txt", "a").write(" ".join(a) + (" stdin-closed" if closed else " stdin-open") + "\n")
mode = open(home + "/ss-mode").read().strip() if os.path.exists(home + "/ss-mode") else "ok"
if mode == "down": sys.stderr.write("stackshot: not reached [0] connection refused\n"); sys.exit(1)
if mode == "hang": time.sleep(30)
if mode == "junk": print("this is not json"); sys.exit(0)
if a == ["get", "state-files"]:
    print(json.dumps({"host": "stub", "generated": "2026-01-01T00:00:00Z", "projects": None if mode == "norecord" else json.load(open(home + "/ss-projects.json")), "fleet": {}, "versions": None, "advertised_commit": ""})); sys.exit(0)
if a == ["get", "roles"]:
    print(open(home + "/ss-roles.json").read()); sys.exit(0)
sys.stderr.write("stub: unexpected %s\n" % " ".join(a)); sys.exit(2)
PY

# mkrec <file> <age in seconds> <key:agent:front|back>… : a schema 1 project record written that many seconds ago, each agent on its project
cat > "$HOME/mkrec.py" <<'PY'
import datetime, json, sys
out, age = sys.argv[1], int(sys.argv[2])
gen = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=age)).strftime("%Y-%m-%dT%H:%M:%SZ")
d = {"schema": 1, "generated": gen, "projects": {}, "by_key": {}}
for spec in sys.argv[3:]:
    key, name, side = spec.split(":")
    pid = "prj_" + format(abs(hash(key)) % 16 ** 8, "08x")
    p = d["projects"].setdefault(pid, {"id": pid, "key": key, "keeper": "", "agents": {}}); d["by_key"][key] = pid
    p["agents"][name] = {"front": side == "front", "role": name.rsplit("-", 1)[-1], "mandate_line": "a line"}
json.dump(d, open(out, "w"))
PY
# mkroles <file> <age> <name:project:role>… : the roles list
cat > "$HOME/mkroles.py" <<'PY'
import datetime, json, sys
out, age = sys.argv[1], int(sys.argv[2])
gen = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=age)).strftime("%Y-%m-%dT%H:%M:%SZ")
d = {"generated": gen, "sessions": {}}
for spec in sys.argv[3:]:
    n, p, r = spec.split(":"); d["sessions"][n] = {"project": p, "role": r, "live": True}
json.dump(d, open(out, "w"))
PY
mkrec() { python3 -I "$HOME/mkrec.py" "$@"; }
mkroles() { python3 -I "$HOME/mkroles.py" "$@"; }
mode() { if [ "$1" = ok ]; then rm -f "$MODE"; else echo "$1" > "$MODE"; fi; }
calls() { local n; n=$(grep -c "^get $1" "$CALLS" 2>/dev/null); echo "${n:-0}"; }   # (grep -c prints 0 and exits 1)
reset() { : > "$CALLS"; rm -f "$LOG" "$MODE" "$HOME/.local/state/salamander/record-live"/*; }

# sx <script>: a fresh bash with lib/common.sh sourced under an empty config; the settings the caller exports are the suite's
sx() { SALA_CONFIG=/dev/null SALA_ROOT="$ROOT" SALA_PROJECT_RECORD="$FILE_REC" SALA_ROLES_FILE="$FILE_ROLES" bash -c '. "$SALA_ROOT/lib/common.sh"; '"$1" 2>&1; }
export SALA_STACKSHOT_CLIENT="$HOME/fake-ss.py"

echo "== stackshot answers: its answer is read, the file copy is not"
mkrec "$FILE_REC" 5 projects/alpha:alpha-main:front projects/alpha:alpha-oldcopy:back
mkrec "$LIVE_REC" 5 projects/alpha:alpha-main:front projects/alpha:alpha-newcomer:back
reset
got=$(sx 'project_record_agent "" alpha-newcomer; echo "rc=$?"')
[ "$got" = "listed on projects/alpha
rc=0" ] && ok "a name only stackshot lists: listed (rc 0), though the file copy does not have it" || bad "live-only name: '$got'"
got=$(sx 'project_record_agent "" alpha-oldcopy; echo "rc=$?"')
has "$got" "rc=3" && has "$got" "on no project of the record" && ok "a name only the file copy lists: not listed (rc 3): the copy is not read while stackshot answers" || bad "copy-only name: '$got'"
got=$(sx 'project_record_agent projects/alpha alpha-newcomer back; echo "rc=$?"')
has "$got" "rc=0" && ok "the spawn gate's own question (the name on the project's map, the role): answered from stackshot" || bad "gate question: '$got'"
[ "$(calls state-files)" = 3 ] && ok "each read asked stackshot (the answer is not kept here: SALA_RECORD_LIVE_TTL=0)" || bad "ask count: $(calls state-files)"
grep -q "get state-files stdin-closed" "$CALLS" && ! grep -q "stdin-open" "$CALLS" && ok "every ask ran with stdin closed" || bad "stdin: $(cat "$CALLS")"
[ ! -s "$LOG" ] && ok "a live answer writes no log line" || bad "log on a live answer: $(cat "$LOG")"
got=$(sx 'record_note projects')
[ -z "$got" ] && ok "record_note is empty when stackshot answered" || bad "note on live: '$got'"
got=$(sx 'project_for_name alpha-newcomer; echo "rc=$?"')
[ "$got" = "projects/alpha
rc=0" ] && ok "project_for_name reads stackshot's answer too" || bad "project_for_name: '$got'"

echo "== stackshot cannot be reached: the file copy, its age said"
mkrec "$FILE_REC" 125 projects/alpha:alpha-main:front projects/alpha:alpha-oldcopy:back
for m in down junk norecord; do
    reset; mode "$m"
    got=$(sx 'project_record_agent "" alpha-oldcopy; echo "rc=$?"')
    has "$got" "rc=0" && ok "stackshot $m: the copy answers (alpha-oldcopy listed)" || bad "$m: '$got'"
    n=$(sx 'record_note projects')
    has "$n" "stackshot did not answer" && has "$n" "$FILE_REC is 2 min" && ok "stackshot $m: the note says it did not answer and the copy's age" || bad "$m note: '$n'"
    has "$(cat "$LOG" 2>/dev/null)" "is 2 min" && ok "stackshot $m: a line in salamander-record.log with the age" || bad "$m log: $(cat "$LOG" 2>/dev/null)"
done
reset; mode down
sx 'project_record_agent "" alpha-oldcopy >/dev/null; project_record_agent "" alpha-main >/dev/null; record_note projects >/dev/null'
[ "$(wc -l < "$LOG")" = 1 ] && ok "three reads in a row leave one log line, not three" || bad "log lines: $(wc -l < "$LOG")"
reset; mode junk
n=$(sx 'record_note projects'); has "$n" "not JSON" && ok "an answer that is not JSON: the note says so" || bad "junk note: '$n'"
reset; mode norecord
n=$(sx 'record_note projects'); has "$n" "no project record to give" && ok "state-files with no record in it: the note says so" || bad "norecord note: '$n'"
reset; mode hang
t0=$SECONDS; got=$(SALA_RECORD_LIVE_TIMEOUT=1 sx 'project_record_agent "" alpha-oldcopy; echo "rc=$?"'); t1=$((SECONDS - t0))
has "$got" "rc=0" && [ "$t1" -lt 10 ] && ok "stackshot hangs: given up after the timeout (${t1} s), the copy answers" || bad "hang: ${t1} s '$got'"
n=$(SALA_RECORD_LIVE_TIMEOUT=1 sx 'record_note projects'); has "$n" "no answer within 1 s" && ok "the note names the timeout" || bad "hang note: '$n'"

echo "== a copy that is too old answers nothing, and the refusal says why"
mkrec "$FILE_REC" 64800 projects/alpha:alpha-main:front
reset; mode down
got=$(sx 'project_record_agent "" alpha-main; echo "rc=$?"')
has "$got" "rc=1" && has "$got" "stale (written 648" && has "$got" "stackshot did not answer" && has "$got" "is 18 h old" && has "$got" "answers nothing" && ok "a stale copy: refused (rc 1) with the stale age, that stackshot was asked first, and the copy's age (18 h)" || bad "stale: '$got'"
rm -f "$FILE_REC"; reset; mode down
got=$(sx 'project_record_agent "" alpha-main; echo "rc=$?"')
has "$got" "rc=1" && has "$got" "no project record at $FILE_REC" && has "$got" "stackshot did not answer" && ok "no copy and no answer: refused, both said" || bad "no copy: '$got'"
mkrec "$FILE_REC" 5 projects/alpha:alpha-main:front

echo "== the answer is kept for a few seconds, a failed ask as long (SALA_RECORD_LIVE_TTL)"
reset; mode ok
sx 'SALA_RECORD_LIVE_TTL=60; for i in 1 2 3; do project_record_agent "" alpha-newcomer >/dev/null; done'
[ "$(calls state-files)" = 1 ] && ok "three reads inside the keeping time: one ask" || bad "kept asks: $(calls state-files)"
mkrec "$LIVE_REC" 5 projects/alpha:alpha-main:front
got=$(sx 'SALA_RECORD_LIVE_TTL=60; project_record_agent "" alpha-newcomer; echo "rc=$?"')
has "$got" "rc=0" && ok "within the keeping time the kept answer is read (what stackshot said a moment ago)" || bad "kept answer: '$got'"
got=$(sx 'project_record_agent "" alpha-newcomer; echo "rc=$?"')
has "$got" "rc=3" && ok "with no keeping time the next read asks again and sees the change" || bad "fresh ask: '$got'"
mkrec "$LIVE_REC" 5 projects/alpha:alpha-main:front projects/alpha:alpha-newcomer:back
reset; mode down
sx 'SALA_RECORD_LIVE_TTL=60; for i in 1 2 3; do project_record_agent "" alpha-main >/dev/null; done'
[ "$(calls state-files)" = 1 ] && ok "a failed ask is kept as long: three reads, one ask (a dead server costs one wait, not three)" || bad "failed asks: $(calls state-files)"

echo "== one copy for the two names of a rename"
reset; mode ok
mkrec "$LIVE_REC" 5 projects/alpha:alpha-main:front projects/alpha:alpha-newcomer:back
got=$(sx 'rename_record_plan alpha-newcomer alpha-renamed; echo "rc=$? hub=$RL_HUB why=$RL_WHY"')
has "$got" "rc=0 hub=projects/alpha" && ok "rename_record_plan: OLD on a project, NEW on none (from stackshot's answer)" || bad "rename plan: '$got'"
[ "$(calls state-files)" = 1 ] && ok "the two names are read from one answer: stackshot is asked once" || bad "rename asks: $(calls state-files)"
reset; mode down
got=$(sx 'rename_record_plan alpha-main alpha-renamed; echo "rc=$? hub=$RL_HUB"')
has "$got" "rc=0 hub=projects/alpha" && ok "stackshot down: the file copy decides the rename (OLD is on it)" || bad "rename on the copy: '$got'"

echo "== the roles list: stackshot first, the copy when it does not answer (retire_project_of)"
mkroles "$LIVE_ROLES" 5 gamma-worker:projects/live-project:back
mkroles "$FILE_ROLES" 130 gamma-worker:projects/copy-project:back
reset
got=$(sx 'retire_project_of gamma-worker; echo "$RETIRE_PROJ | $RETIRE_PROJ_SRC"')
[ "$got" = "projects/live-project | stackshot's roles list (client.py get roles)" ] && ok "retire: the project is the one stackshot's list gives, not the copy's" || bad "retire live: '$got'"
mode down
got=$(sx 'retire_project_of gamma-worker; echo "$RETIRE_PROJ | $RETIRE_PROJ_SRC"')
has "$got" "projects/copy-project |" && has "$got" "the file copy:" && has "$got" "is 2 min" && has "$got" "stackshot did not answer" && ok "retire, stackshot down: the copy's project, and the source line says it is a copy and how old" || bad "retire copy: '$got'"
mkroles "$FILE_ROLES" 64800 gamma-worker:projects/copy-project:back
got=$(sx 'retire_project_of gamma-worker; echo "[$RETIRE_PROJ] | $RETIRE_PROJ_SRC"')
has "$got" "[projects/copy-project]" && has "$got" "is 18 h old" && ok "retire, an 18 h copy: read as before (the name is all it asks), and the source line says how old the copy is" || bad "retire stale copy: '$got'"

echo "== the Python reader, as a command and as bgagents.py uses it"
mkrec "$LIVE_REC" 5 projects/alpha:alpha-main:front projects/alpha:alpha-newcomer:back
mkrec "$FILE_REC" 125 projects/alpha:alpha-main:front projects/alpha:alpha-oldcopy:back
mkroles "$LIVE_ROLES" 5 alpha-newcomer:projects/alpha:back
mkroles "$FILE_ROLES" 125 alpha-oldcopy:projects/alpha:back
reset
out=$(python3 -I "$ROOT/lib/stackshot_record.py" resolve projects --fallback "$FILE_REC" --max-age 600 --client "$SALA_STACKSHOT_CLIENT" --state-dir "$HOME/.local/state/salamander" --log-dir "$HOME/.claude" --ttl 0); rc=$?
IFS=$'\t' read -r p s n w <<< "$out"
[ "$rc" = 0 ] && [ "$s" = live ] && [ -z "$n" ] && [ "$p" != "$FILE_REC" ] && python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["schema"]==1 and "alpha-newcomer" in d["projects"][d["by_key"]["projects/alpha"]]["agents"] else 1)' "$p" && ok "the command: source live, a file holding stackshot's record (schema 1)" || bad "command live: rc=$rc '$out'"
mode down
out=$(python3 -I "$ROOT/lib/stackshot_record.py" resolve projects --fallback "$FILE_REC" --max-age 600 --client "$SALA_STACKSHOT_CLIENT" --state-dir "$HOME/.local/state/salamander" --log-dir "$HOME/.claude" --ttl 0); rc=$?
IFS=$'\t' read -r p s n w <<< "$out"
[ "$rc" = 0 ] && [ "$s" = file ] && [ "$p" = "$FILE_REC" ] && has "$n" "is 2 min" && [ -n "$w" ] && ok "the command, stackshot down: source file, the copy's path, its age and why stackshot did not answer" || bad "command down: rc=$rc '$out'"
out=$(python3 -I "$ROOT/lib/stackshot_record.py" resolve projects --fallback "$HOME/nothing.json" --max-age 600 --client "$SALA_STACKSHOT_CLIENT" --state-dir "$HOME/.local/state/salamander" --log-dir "$HOME/.claude" --ttl 0); rc=$?
IFS=$'\t' read -r p s n w <<< "$out"
[ "$rc" = 1 ] && [ "$s" = none ] && [ "$p" = "$HOME/nothing.json" ] && ok "the command, nothing to read: exit 1, source none, the copy's path still printed" || bad "command none: rc=$rc '$out'"
python3 -I "$ROOT/lib/stackshot_record.py" resolve nothing >/dev/null 2>&1; [ $? = 2 ] && ok "a bad kind is a usage error (exit 2)" || bad "bad kind exit"
cat > "$HOME/bg.py" <<'PY'
import os, sys, time
sys.path.insert(0, sys.argv[1]); import bgagents
now = int(time.time())
print(bgagents.agent_on_map("projects/alpha", "alpha-newcomer", now), bgagents.agent_on_map("projects/alpha", "alpha-oldcopy", now))
print(bgagents.record_link("alpha-newcomer", "projects/alpha", "back", now)[0], bgagents.roles_link("alpha-newcomer", "projects/alpha", "back", now)[0])
print(bgagents.record_link("alpha-oldcopy", "projects/alpha", "back", now)[0], bgagents.roles_link("alpha-oldcopy", "projects/alpha", "back", now)[0])
PY
export SALA_PROJECT_RECORD="$FILE_REC" SALA_ROLES_FILE="$FILE_ROLES" SALA_STATE_DIR="$HOME/.local/state/salamander" SALA_LOG_DIR="$HOME/.claude"
mode ok; reset
got=$(python3 -I -S "$HOME/bg.py" "$ROOT/lib"); [ "$got" = "True False
ok ok
no no" ] && ok "bgagents.py, stackshot answering: the project record (agent_on_map, link 1) and the roles list (link 2) are stackshot's, the copy's names are not on them" || bad "bgagents live: '$got'"
reset; mode down
got=$(python3 -I -S "$HOME/bg.py" "$ROOT/lib"); [ "$got" = "False True
no no
ok ok" ] && ok "bgagents.py, stackshot down: the copies answer" || bad "bgagents down: '$got'"
mkrec "$FILE_REC" 64800 projects/alpha:alpha-main:front
reset; mode down
got=$(python3 -I -S -c 'import sys,time; sys.path.insert(0, sys.argv[1]); import bgagents; r = bgagents.record_link("alpha-main", "projects/alpha", "front", int(time.time())); print(r[0] + " | " + r[1])' "$ROOT/lib")
has "$got" "cannot | it is stale (written" && has "$got" "stackshot did not answer" && has "$got" "is 18 h old" && ok "bgagents.py: a stale copy is a link that cannot answer, and the reason says stackshot was asked and the copy's age" || bad "bgagents stale: '$got'"
unset SALA_PROJECT_RECORD SALA_ROLES_FILE SALA_STATE_DIR SALA_LOG_DIR
mkrec "$FILE_REC" 5 projects/alpha:alpha-main:front projects/alpha:alpha-oldcopy:back

echo "== no ask at all: SALA_RECORD_LIVE=off, and a box with no client"
reset; mode ok
got=$(SALA_RECORD_LIVE=off sx 'project_record_agent "" alpha-newcomer; echo "rc=$?"')
has "$got" "rc=3" && [ "$(calls state-files)" = 0 ] && ok "SALA_RECORD_LIVE=off: the copy alone, stackshot is not asked" || bad "live off: '$got' calls=$(calls state-files)"
got=$(SALA_STACKSHOT_CLIENT= sx 'project_record_agent "" alpha-oldcopy; echo "rc=$?"; record_note projects')
has "$got" "rc=0" && [ "$(calls state-files)" = 0 ] && [ ! -s "$LOG" ] && ok "no client on the box: the copy is read, nothing is asked, nothing is logged (the copy is all there is)" || bad "no client: '$got' log=$(cat "$LOG" 2>/dev/null)"
has "$got" "$FILE_REC is" && ok "and the note still says how old the copy is" || bad "no client note: '$got'"

[ "$fail" = 0 ] && echo "recordlive: pass" || echo "recordlive: FAIL"
exit "$fail"
