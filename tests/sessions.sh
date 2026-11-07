#!/usr/bin/env bash
# The session registry, phase 1 (Wed Oct 21st 2026; lib/sessions.py, common.sh "THE SESSION REGISTRY", lib/sessions.sh,
# docs/session-registry.md): $SALA_STATE_DIR/sessions.json, one row per session, dual-written by ledger_write AFTER the pane-map
# write, and nothing reads it. Checked here: the id minted on add and kept across renames (the old name an alias) and a retire
# (the row stays, state=retired); re-adding a retired name mints a new id; follow changes nothing; lane_write, model_write,
# model_drop and the spawn --project/--role copy land in the row (and mint one for a mapped session that has none); a kill
# between the two writes (an add, a rename, a retire the registry never saw) is found and repaired by `sala sessions --check`,
# and only reported by --dry-run; `sala sessions --migrate --dry-run` prints the rows a seeded pane map would make and writes
# nothing, the real one makes them (lane, model, aliases from the tables and renames.jsonl); a registry that fails (a corrupt
# file, a missing helper) never breaks the pane-map write, which stays byte-identical to a run with SALA_SESSIONS=off; off writes
# nothing; the registry shares the pane map's lock; eight parallel adds all land. No tmux server and no fake claude: the map
# functions run in a sandbox HOME, and `sala sessions` runs as the verb. Not checked: a real spawn/rename/retire end to end (their
# own suites run them with the registry on: tests/ledger.sh, retire.sh, ledger-recycle.sh compare map files), a production dry run.
# PHASE 2 (Thu Oct 22nd 2026, the end of this file): `sala sessions record` (by name, id and id prefix; idempotent; the errors; off; the
# lock), sessions_prepare/sessions_abandon, and `salamander hook session-start` per source, with garbage on stdin and as the fallback by
# the pane's tmux session name (a private tmux server, no claude). The spawn and unpark halves are tests/sessions-spawn.sh.
# PHASE 3 (Thu Oct 22nd 2026, the end of this file): the heartbeat's session-registry.json (contents, `written` refreshed every run, atomic,
# nothing published when off / missing / corrupt and the last good file kept with one log line) and `sala sessions resolve` (id, prefix,
# transcript, name, alias, role:; retired with and without --live; ambiguous = exit 2 with every candidate id, none = exit 1; read-only).
# Hand-made sessions.json fixtures in a temporary state dir; the heartbeat runs with no fleet hosts (this box only).
# PHASE 4 (Sat Oct 24th 2026, the end of this file): `sala sessions tag` fills project/role of a live row (by name, id, 8-character prefix;
# --project-key as the same field; --dry-run; idempotent; the argument and unknown-session errors; a retired row; off; a corrupt file; the
# lock) and `resolve role:<project>/<role>` finds the row afterwards.
# Usage: bash tests/sessions.sh   (exit 0 = pass; ~25 s)
set -u
unset TMUX TMUX_PANE XDG_STATE_HOME
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"   # short timings, ok/bad/waitfor
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects" "$HOME/.local/share/tmux/resurrect"
export SALA_AUTO_UPDATE=off SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_LEDGER_CALLER=sessions-test
SALA="$ROOT/bin/salamander"; SOCK="sala-sessions-$$"
export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # no server runs on it: on_fleet_server is true, tmux calls find nothing
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux   # never the real server, whatever the environment
cleanup() { tmux_socket_rm; rm -rf "$HOME" 2>/dev/null; true; }; trap cleanup EXIT
. "$ROOT/lib/common.sh"; MAP="$SALA_SIDECAR"; REG="$SALA_SESSIONS_FILE"; RLOG="$SALA_SESSIONS_LOG"
U1=aaaaaaaa-0000-4000-8000-000000000001 U2=bbbbbbbb-0000-4000-8000-000000000002 U3=cccccccc-0000-4000-8000-000000000003
U4=dddddddd-0000-4000-8000-000000000004 U5=eeeeeeee-0000-4000-8000-000000000005

# regq <file> <name|id8|-all> <field> → the field of the NEWEST row with that name (live or retired), as JSON; "count <state>" counts rows
cat > "$HOME/regq.py" <<'PY'
import json, sys
f, mode = sys.argv[1], sys.argv[2]
d = json.load(open(f))
rows = sorted(d["sessions"].values(), key=lambda r: r["created"])
if mode == "count":
    print(sum(1 for r in rows if sys.argv[3] == "any" or r["state"] == sys.argv[3])); sys.exit()
if mode == "rows":
    print(len(rows)); sys.exit()
c = [r for r in rows if r["name"] == mode and (len(sys.argv) < 5 or r["state"] == sys.argv[4])]
print(json.dumps(c[-1].get(sys.argv[3]) if c else "<none>"))
PY
q() { python3 "$HOME/regq.py" "$REG" "$@"; }   # q <name> <field> [state]
qn() { python3 "$HOME/regq.py" "$REG" count "$1"; }   # qn <live|retired|any>
mapline() { printf '%s\t%s\t%s\t%s\n' "$@"; }

echo "== add mints a row; the pane map is written first and untouched by it"
ledger_write add alpha "$U1" alpha "$HOME/wa" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(<"$MAP")" = "$(mapline alpha "$U1" alpha "$HOME/wa")" ] && ok "the pane map holds the row" || bad "rc=$rc map: $(slurp "$MAP")"
[ -s "$REG" ] && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$REG" && ok "sessions.json is valid JSON" || bad "no registry: $(slurp "$REG")"
ID1=$(q alpha id | tr -d '"')
[[ "$ID1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] && ok "the id is a uuid4" || bad "id: $ID1"
[ "$(q alpha pane)" = '"alpha"' ] && [ "$(q alpha cwd)" = "\"$HOME/wa\"" ] && [ "$(q alpha state)" = '"live"' ] && [ "$(q alpha aliases)" = '[]' ] && ok "name, pane, cwd, state and aliases are the map's" || bad "row: $(<"$REG")"
[ "$(q alpha transcripts | python3 -c 'import json,sys; t=json.load(sys.stdin); print(len(t), t[0]["id"], t[0]["why"])')" = "1 $U1 add" ] && ok "transcripts[0] is the conversation (why: add)" || bad "transcripts: $(q alpha transcripts)"
[ "$(q alpha machine)" != '"<none>"' ] && [ "$(q alpha machine)" != 'null' ] && [ "$(q alpha created)" != 'null' ] && ok "machine and created are set" || bad "machine/created: $(q alpha machine) $(q alpha created)"
for k in project role lane model effort; do [ "$(q alpha $k)" = null ] || bad "$k should be null: $(q alpha $k)"; done; ok "project, role, lane, model and effort start empty"

echo "== the id survives a rename (the old name becomes an alias) and a repeated add reuses the row"
ledger_write add alpha "$U1" alpha "$HOME/wa" >/dev/null 2>&1
[ "$(qn live)" = 1 ] && ok "a repeated add makes no second row" || bad "rows: $(qn live)"
ledger_write rename alpha beta "$U1" "$HOME/wa" >/dev/null 2>&1
[ "$(q beta id | tr -d '"')" = "$ID1" ] && ok "the id is the same after the rename" || bad "id after rename: $(q beta id) vs $ID1"
[ "$(q beta aliases)" = '["alpha"]' ] && [ "$(q beta pane)" = '"beta"' ] && [ "$(q alpha id)" = '"<none>"' ] && ok "name and pane are beta, alpha is an alias, no row is named alpha" || bad "row: $(<"$REG")"
ledger_write rename beta gamma "$U1" "$HOME/wa" >/dev/null 2>&1
[ "$(q gamma id | tr -d '"')" = "$ID1" ] && [ "$(q gamma aliases)" = '["alpha", "beta"]' ] && ok "a second rename keeps the id and appends the alias" || bad "after the second rename: $(q gamma aliases) $(q gamma id)"
[ "$(<"$MAP")" = "$(mapline gamma "$U1" gamma "$HOME/wa")" ] && ok "the pane map shows the rename as before" || bad "map: $(<"$MAP")"

echo "== follow changes nothing in the registry"
cp "$REG" "$HOME/reg.before"
ledger_write follow gamma "$U2" "$HOME/wb" >/dev/null 2>&1
[ "$(cut -f2 "$MAP")" = "$U2" ] && same_file "$REG" "$HOME/reg.before" && ok "the map followed the conversation; sessions.json is byte-identical" || bad "map: $(<"$MAP")"
ledger_write follow gamma "$U1" "$HOME/wa" >/dev/null 2>&1

echo "== lane_write, model_write, model_drop and the project/role copy land in the row"
lane_write gamma api >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(q gamma lane)" = '"api"' ] && ok "lane_write copies the lane (return status as before)" || bad "rc=$rc lane=$(q gamma lane)"
lane_write gamma nonsense >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && [ "$(q gamma lane)" = '"api"' ] && ok "an unknown lane is refused as before and changes nothing" || bad "rc=$rc lane=$(q gamma lane)"
model_write gamma opus high >/dev/null 2>&1
[ "$(q gamma model)" = '"opus"' ] && [ "$(q gamma effort)" = '"high"' ] && ok "model_write copies model and effort" || bad "model=$(q gamma model) effort=$(q gamma effort)"
model_write gamma sonnet >/dev/null 2>&1
[ "$(q gamma model)" = '"sonnet"' ] && [ "$(q gamma effort)" = null ] && ok "no effort given: the row's effort is empty, like the table's -" || bad "model=$(q gamma model) effort=$(q gamma effort)"
model_drop gamma >/dev/null 2>&1
[ "$(q gamma model)" = null ] && ok "model_drop (sala model --clear) empties them" || bad "model=$(q gamma model)"
sessions_set gamma project=projects/demo role=front >/dev/null 2>&1
[ "$(q gamma project)" = '"projects/demo"' ] && [ "$(q gamma role)" = '"front"' ] && ok "spawn's --project/--role copy (sessions_set) lands" || bad "project=$(q gamma project) role=$(q gamma role)"
ledger_write add delta "$U3" delta "$HOME/wd" >/dev/null 2>&1
python3 - "$REG" <<'PY'   # the registry loses delta's row (it was never recorded, say)
import json, sys
d = json.load(open(sys.argv[1]))
d["sessions"] = {k: v for k, v in d["sessions"].items() if v["name"] != "delta"}
json.dump(d, open(sys.argv[1], "w"))
PY
lane_write delta subscription-2 >/dev/null 2>&1
[ "$(q delta lane)" = '"subscription-2"' ] && [ "$(q delta transcripts | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])')" = "$U3" ] && ok "a mapped session with no row gets one from the map on its first field write" || bad "delta: $(q delta lane) $(q delta transcripts)"
lane_write nomap api >/dev/null 2>&1
[ "$(q nomap id)" = '"<none>"' ] && ok "a session that is not in the pane map gets no row from a field write" || bad "nomap: $(q nomap id)"

echo "== retire keeps the row; re-adding the name mints a new id; history copies are kept"
ledger_write retire delta >/dev/null 2>&1
[ "$(q delta state)" = '"retired"' ] && [ "$(q delta retired_at)" != null ] && ! grep -q "^delta	" "$MAP" && ok "retire: the map row is gone, the registry row stays, state=retired" || bad "delta: $(q delta state); map: $(<"$MAP")"
OLDD=$(q delta id | tr -d '"')
ledger_write add delta "$U4" delta "$HOME/wd" >/dev/null 2>&1
NEWD=$(q delta id live | tr -d '"')
[ "$NEWD" != "$OLDD" ] && [ "$NEWD" != '<none>' ] && [ "$(q delta state live)" = '"live"' ] && ok "re-adding a retired name mints a new id" || bad "old $OLDD new $NEWD"
[ "$(python3 - "$REG" "$OLDD" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); r = d["sessions"][sys.argv[2]]; print(r["state"], r["transcripts"][0]["id"])
PY
)" = "retired $U3" ] && ok "the retired row is untouched by the new one" || bad "retired row changed"
[ -n "$(ls "$SALA_SESSIONS_HISTORY" 2>/dev/null)" ] && ok "sessions-history/ holds the copies of the file before each change" || bad "no history: $(ls "$SALA_SESSIONS_HISTORY" 2>&1)"
grep -q "	retire	delta	" "$RLOG" && grep -q "	rename	alpha	" "$RLOG" && ok "sessions.log has a line for the retire and the rename" || bad "log: $(<"$RLOG")"

echo "== sala sessions: the listing"
out=$("$SALA" sessions 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q "^ID " && echo "$out" | grep -q " gamma " && echo "$out" | grep -q "alpha,beta" && ! echo "$out" | grep -qE '^[0-9a-f]{8} +[a-z0-9]+ +retired' && ok "lists live rows with their aliases, not the retired one" || bad "rc=$rc: $out"
"$SALA" sessions --all 2>&1 | grep -q retired && ok "--all adds the retired" || bad "--all: no retired row"
"$SALA" sessions --all --json 2>&1 | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["schema"]==1 and len(d["sessions"])>=3' && ok "--json is the rows as JSON" || bad "--json"

echo "== a kill between the two writes: an add, a rename and a retire the registry never saw"
sessions_dual_write() { return 0; }   # the registry's half "killed" for the next calls
ledger_write add eps "$U5" eps "$HOME/we" >/dev/null 2>&1                      # add never recorded
ledger_write rename gamma gamma2 "$U1" "$HOME/wa" >/dev/null 2>&1              # rename never recorded
ledger_write retire delta >/dev/null 2>&1                                      # retire never recorded
unset -f sessions_dual_write; . "$ROOT/lib/common.sh"
cp "$REG" "$HOME/reg.drift"
out=$("$SALA" sessions --check --dry-run 2>&1); rc=$?
[ "$rc" = 1 ] && echo "$out" | grep -q "would repair: eps: in the pane map, no live registry row" && echo "$out" | grep -q "would repair: gamma2: the registry row .* still has the name before the rename" && echo "$out" | grep -q "would repair: delta: live in the registry, no pane-map row" && ok "--check --dry-run exits 1 and names the three drifts" || bad "rc=$rc: $out"
same_file "$REG" "$HOME/reg.drift" && ok "--dry-run wrote nothing" || bad "dry run changed the registry"
out=$("$SALA" sessions --check 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q "repaired: eps" && ok "--check repairs and exits 0" || bad "rc=$rc: $out"
[ "$(q eps transcripts | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])')" = "$U5" ] && ok "the missed add: a row for eps from the map" || bad "eps: $(q eps id)"
[ "$(q gamma2 id | tr -d '"')" = "$ID1" ] && [ "$(q gamma2 aliases)" = '["alpha", "beta", "gamma"]' ] && ok "the missed rename: the same id under the new name, the old name an alias" || bad "gamma2: $(q gamma2 id) $(q gamma2 aliases)"
[ "$(q delta state live)" = '"<none>"' ] && ok "the missed retire: no live delta row" || bad "delta live: $(q delta id live)"
out=$("$SALA" sessions --check 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q "consistent" && ok "a second --check finds it consistent" || bad "rc=$rc: $out"
lane_write eps subscription-1 >/dev/null 2>&1; python3 - "$REG" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for r in d["sessions"].values():
    if r["name"] == "eps": r["lane"] = "api"
json.dump(d, open(sys.argv[1], "w"))
PY
"$SALA" sessions --check 2>&1 | grep -q "repaired: eps: lane differ" && [ "$(q eps lane)" = '"subscription-1"' ] && ok "a lane the table and the row disagree on is repaired to the table's" || bad "lane drift: $(q eps lane)"

echo "== sala sessions --migrate: --dry-run prints what a seeded pane map would make, then the real run"
H2="$HOME/h2"; mkdir -p "$H2/.claude" "$H2/.local/state/salamander"
S2="$H2/.local/state/salamander"
printf 'one\t%s\tone\t/w/one\ntwo\t%s\ttwo\t/w/two\nthree\t%s\tthree\t/w/three\n' "$U1" "$U2" "$U3" > "$S2/pane-map.tsv"
printf 'two\tapi\nthree\tsubscription-2\n' > "$S2/lanes.tsv"
printf 'one\topus\thigh\nthree\tsonnet\t-\n' > "$S2/models.tsv"
printf '{"uuid":"%s","from":"uno","to":"one","at":"2026-10-01T00:00:00Z","bridge":""}\n{"uuid":"%s","from":"first","to":"uno","at":"2026-09-01T00:00:00Z","bridge":""}\n{"uuid":"%s","from":"zwei","to":"two","at":"2026-10-02T00:00:00Z","bridge":""}\n' "$U1" "$U1" "$U2" > "$H2/.claude/salamander-renames.jsonl"
mig() ( export HOME="$H2" SALA_LOG_DIR="$H2/.claude"; unset SALA_SIDECAR SALA_SESSIONS_FILE; "$SALA" sessions --migrate "$@" 2>&1 )
out=$(mig --dry-run); rc=$?
[ "$rc" = 0 ] && [ "$(echo "$out" | grep -c '^would mint')" = 3 ] && echo "$out" | grep -q "3 pane-map rows, 3 to mint, 0 already" && ok "--dry-run: one 'would mint' line per pane-map row" || bad "rc=$rc: $out"
echo "$out" | grep -q "^would mint	one	pane=one	uuid=$U1	cwd=/w/one	lane=-	model=opus	effort=high	aliases=uno,first$" \
    && echo "$out" | grep -q "^would mint	two	pane=two	uuid=$U2	cwd=/w/two	lane=api	model=-	effort=-	aliases=zwei$" \
    && echo "$out" | grep -q "^would mint	three	pane=three	uuid=$U3	cwd=/w/three	lane=subscription-2	model=sonnet	effort=-	aliases=-$" && ok "each line carries the map's session, conversation and cwd, the tables' lane/model/effort, the renames' aliases" || bad "lines: $out"
[ ! -e "$S2/sessions.json" ] && ok "--dry-run wrote no file" || bad "the dry run made $S2/sessions.json"
out=$(mig); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q "3 minted" && [ "$(python3 "$HOME/regq.py" "$S2/sessions.json" count live)" = 3 ] && ok "the real run makes the three rows" || bad "rc=$rc: $out"
python3 - "$S2/sessions.json" "$U1" "$U2" "$U3" <<'PY' && ok "rows: transcripts[0] is the map's conversation with why=import; lane, model, effort and aliases from the tables" || bad "migrated rows differ"
import json, sys
d = json.load(open(sys.argv[1])); by = {r["name"]: r for r in d["sessions"].values()}
u1, u2, u3 = sys.argv[2:5]
o, t, h = by["one"], by["two"], by["three"]
assert [(x["id"], x["why"]) for x in o["transcripts"]] == [(u1, "import")] and o["model"] == "opus" and o["effort"] == "high" and o["lane"] is None
assert o["aliases"] == ["uno", "first"] and t["aliases"] == ["zwei"] and t["lane"] == "api" and t["transcripts"][0]["id"] == u2
assert h["lane"] == "subscription-2" and h["model"] == "sonnet" and h["effort"] is None and h["cwd"] == "/w/three" and h["pane"] == "three"
assert all(r["state"] == "live" and r["id"] for r in by.values()) and len({r["id"] for r in by.values()}) == 3
PY
out=$(mig); echo "$out" | grep -q "0 minted, 3 already have a live registry row" && ok "a second run mints nothing" || bad "second run: $out"
out=$(mig --dry-run); echo "$out" | grep -q "0 to mint, 3 already" && ok "and its dry run says so" || bad "dry run after: $out"
[ "$(cut -f1,2,3,4 "$S2/pane-map.tsv" | md5sum)" = "$(printf 'one\t%s\tone\t/w/one\ntwo\t%s\ttwo\t/w/two\nthree\t%s\tthree\t/w/three\n' "$U1" "$U2" "$U3" | md5sum)" ] && ok "the migration never touched the pane map" || bad "the migration changed the pane map"

echo "== a registry that fails never breaks the pane-map write"
seq_ops() {  # the same writes against one map: a pane map's bytes are what the existing suites compare
    ledger_write add p1 "$U1" p1 /w/1; ledger_write add p2 "$U2" p2 /w/2; ledger_write rename p1 q1 "$U1" /w/1
    ledger_write follow p2 "$U3" /w/3; ledger_write retire p2; ledger_write add p3 "$U4" p3 /w/4; lane_write p3 api; model_write p3 opus high
} >/dev/null 2>&1
for mode in off write broken; do
    d="$HOME/cmp-$mode"; mkdir -p "$d"
    ( export SALA_SIDECAR="$d/pane-map.tsv"; unset SALA_SESSIONS_FILE; SALA_SESSIONS=write
      [ "$mode" = off ] && SALA_SESSIONS=off
      . "$ROOT/lib/common.sh"
      [ "$mode" = broken ] && { printf 'this is not json {' > "$SALA_SESSIONS_FILE"; }
      SALA_LANES="$d/lanes.tsv" SALA_MODELS="$d/models.tsv" seq_ops )
done
same_file "$HOME/cmp-off/pane-map.tsv" "$HOME/cmp-write/pane-map.tsv" && same_file "$HOME/cmp-off/pane-map.tsv" "$HOME/cmp-broken/pane-map.tsv" && [ "$(wc -l < "$HOME/cmp-off/pane-map.tsv")" = 2 ] \
    && ok "the pane map is byte-identical with the registry off, on, and on a corrupt file (2 rows)" || bad "maps differ: off $(<"$HOME/cmp-off/pane-map.tsv") | write $(<"$HOME/cmp-write/pane-map.tsv") | broken $(<"$HOME/cmp-broken/pane-map.tsv")"
[ "$(<"$HOME/cmp-broken/sessions.json")" = 'this is not json {' ] && grep -q "	error	" "$HOME/cmp-broken/sessions.log" && ok "a corrupt registry is left as it was and logged, never overwritten" || bad "broken: $(<"$HOME/cmp-broken/sessions.json") | $(cat "$HOME/cmp-broken/sessions.log" 2>&1)"
( export SALA_SIDECAR="$HOME/cmp-broken/pane-map.tsv"; unset SALA_SESSIONS_FILE; . "$ROOT/lib/common.sh"
  ledger_write add p9 "$U5" p9 /w/9 >/dev/null 2>&1; echo "rc=$?" > "$HOME/rc.add"
  out=$("$SALA" sessions 2>&1); echo "rc=$?" > "$HOME/rc.list"; echo "$out" > "$HOME/out.list" )
[ "$(<"$HOME/rc.add")" = rc=0 ] && grep -q "^p9	" "$HOME/cmp-broken/pane-map.tsv" && ok "an add against the corrupt file still returns 0 with the row in the map" || bad "add rc: $(<"$HOME/rc.add")"
[ "$(<"$HOME/rc.list")" = rc=1 ] && grep -q "not readable JSON" "$HOME/out.list" && ok "sala sessions says the file is unreadable (exit 1)" || bad "list: $(<"$HOME/rc.list") $(<"$HOME/out.list")"
( export SALA_SIDECAR="$HOME/cmp-write/pane-map.tsv"; unset SALA_SESSIONS_FILE; . "$ROOT/lib/common.sh"; SALA_SESSIONS_PY=/nonexistent/sessions.py
  ledger_write add p8 "$U5" p8 /w/8 >/dev/null 2>&1; echo "rc=$?" > "$HOME/rc.nopy" )
[ "$(<"$HOME/rc.nopy")" = rc=0 ] && grep -q "^p8	" "$HOME/cmp-write/pane-map.tsv" && grep -q "add p8 failed" "$HOME/cmp-write/sessions.log" && ok "a missing helper: the map write returns 0 and the failure is one log line" || bad "nopy: $(<"$HOME/rc.nopy"); log: $(tail -2 "$HOME/cmp-write/sessions.log")"

echo "== SALA_SESSIONS=off writes nothing"
D3="$HOME/off3"; mkdir -p "$D3"
( export SALA_SIDECAR="$D3/pane-map.tsv" SALA_SESSIONS=off; unset SALA_SESSIONS_FILE; . "$ROOT/lib/common.sh"
  ledger_write add o1 "$U1" o1 /w/o >/dev/null 2>&1; lane_write o1 api >/dev/null 2>&1; model_write o1 opus >/dev/null 2>&1; ledger_write rename o1 o2 "$U1" /w/o >/dev/null 2>&1; ledger_write retire o2 >/dev/null 2>&1 )
[ -z "$(ls "$D3" | grep -E 'sessions' )" ] && ok "no sessions.json, log or history after add, lane, model, rename and retire" || bad "off wrote: $(ls "$D3")"
out=$(SALA_SESSIONS=off SALA_SIDECAR="$D3/pane-map.tsv" "$SALA" sessions --migrate 2>&1); rc=$?
[ "$rc" = 1 ] && echo "$out" | grep -q "SALA_SESSIONS=off" && [ ! -e "$D3/sessions.json" ] && ok "--migrate and --check refuse to write under off" || bad "rc=$rc: $out"

echo "== the registry shares the pane map's lock; parallel adds all land"
D4="$HOME/lock4"; mkdir -p "$D4"
( export SALA_SIDECAR="$D4/pane-map.tsv"; unset SALA_SESSIONS_FILE; . "$ROOT/lib/common.sh"
  ledger_write add l1 "$U1" l1 /w/l >/dev/null 2>&1
  ( flock 6; sleep 3 ) 6>>"$SALA_SIDECAR.lock" & H=$!; sleep 0.5
  t0=$(date +%s); lane_write l1 api >/dev/null 2>&1; t1=$(date +%s); wait "$H"
  echo "$((t1 - t0))" > "$HOME/lock.wait"; python3 "$HOME/regq.py" "$SALA_SESSIONS_FILE" l1 lane > "$HOME/lock.lane" )
[ "$(<"$HOME/lock.wait")" -ge 2 ] && [ "$(<"$HOME/lock.lane")" = '"api"' ] && ok "a field copy waits for the pane map's lock, then lands ($(<"$HOME/lock.wait") s)" || bad "wait $(<"$HOME/lock.wait") lane $(<"$HOME/lock.lane")"
D5="$HOME/par5"; mkdir -p "$D5"
( export SALA_SIDECAR="$D5/pane-map.tsv"; unset SALA_SESSIONS_FILE; . "$ROOT/lib/common.sh"
  for i in 1 2 3 4 5 6 7 8; do ( ledger_write add "w$i" "00000000-0000-4000-8000-00000000000$i" "w$i" "/w/$i" >/dev/null 2>&1 ) & done; wait
  echo "$(wc -l < "$SALA_SIDECAR") $(python3 "$HOME/regq.py" "$SALA_SESSIONS_FILE" count live) $(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d["sessions"]), len({r["name"] for r in d["sessions"].values()}))' "$SALA_SESSIONS_FILE")" > "$HOME/par.out" )
[ "$(<"$HOME/par.out")" = "8 8 8 8" ] && ok "eight parallel adds: 8 map rows, 8 live registry rows, 8 distinct names, a valid file" || bad "parallel: $(<"$HOME/par.out")"

echo "== phase 2: sessions record appends a conversation once, by id, id prefix or live name"
R1=11111111-0000-4000-8000-0000000000a1; R2=11111111-0000-4000-8000-0000000000a2; R3=11111111-0000-4000-8000-0000000000a3
ledger_write add rec1 "$R1" rec1 "$HOME/wr" >/dev/null 2>&1
RID=$(q rec1 id | tr -d '"')
ntr() { q "$1" transcripts | python3 -c 'import json,sys; t=json.load(sys.stdin); print(len(t), " ".join(x["id"]+":"+x["why"] for x in t[1:]))'; }   # ntr <name> → "<count> <id:why of the later ones>"
out=$("$SALA" sessions record rec1 --transcript "$R2" --why clear 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(ntr rec1)" = "2 $R2:clear" ] && ok "record by name: the conversation joins the row (why: clear), exit 0" || bad "rc=$rc $out :: $(ntr rec1)"
cp "$REG" "$HOME/reg.before"
out=$("$SALA" sessions record rec1 --transcript "$R2" --why clear 2>&1); rc=$?
[ "$rc" = 0 ] && same_file "$REG" "$HOME/reg.before" && ok "the same conversation twice is a no-op (sessions.json byte-identical)" || bad "repeat: rc=$rc $out"
out=$("$SALA" sessions record "$RID" --transcript "$R2" --why resume 2>&1); rc=$?
[ "$rc" = 0 ] && same_file "$REG" "$HOME/reg.before" && ok "a listed conversation is a no-op whatever the why (by id)" || bad "repeat by id: rc=$rc $out"
out=$("$SALA" sessions record "$RID" --transcript "$R3" --why resume --machine zz 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(ntr rec1)" = "3 $R2:clear $R3:resume" ] && [ "$(q rec1 transcripts | python3 -c 'import json,sys; print(json.load(sys.stdin)[2]["machine"])')" = zz ] && ok "record by id, --machine kept on the entry" || bad "by id: rc=$rc $out :: $(ntr rec1)"
R4=11111111-0000-4000-8000-0000000000a4
out=$("$SALA" sessions record "${RID:0:8}" --transcript "$R4" --why start 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(ntr rec1)" = "4 $R2:clear $R3:resume $R4:start" ] && ok "record by the 8-character id prefix sessions lists" || bad "by prefix: rc=$rc $out :: $(ntr rec1)"
cp "$REG" "$HOME/reg.before"
for badargs in "nosuchname --transcript $R2 --why clear" "00000000-0000-4000-8000-ffffffffffff --transcript $R2 --why clear" "deadbeef --transcript $R2 --why clear"; do
    out=$("$SALA" sessions record $badargs 2>&1); rc=$?
    [ "$rc" != 0 ] && echo "$out" | grep -q "no session" && same_file "$REG" "$HOME/reg.before" && ok "unknown session '${badargs%% *}': clear error, non-zero, nothing written" || bad "unknown '${badargs%% *}': rc=$rc $out"
done
for badargs in "rec1 --transcript $R2" "rec1 --why clear" "rec1 --transcript $R2 --why add" "rec1 --transcript $R2 --why bogus" "--transcript $R2 --why clear" "rec1 --transcript bad/id --why clear"; do
    out=$("$SALA" sessions record $badargs 2>&1); rc=$?
    [ "$rc" != 0 ] && same_file "$REG" "$HOME/reg.before" && ok "bad arguments ($badargs): refused, nothing written" || bad "args '$badargs': rc=$rc $out"
done
ledger_write retire rec1 >/dev/null 2>&1
out=$("$SALA" sessions record rec1 --transcript "$R2" --why clear 2>&1); rc=$?
[ "$rc" != 0 ] && echo "$out" | grep -q "no session" && ok "a retired session's name no longer resolves" || bad "retired name: rc=$rc $out"
D6="$HOME/off6"; mkdir -p "$D6"
( export SALA_SIDECAR="$D6/pane-map.tsv" SALA_SESSIONS=write; unset SALA_SESSIONS_FILE; . "$ROOT/lib/common.sh"; ledger_write add o6 "$R1" o6 /w/o6 >/dev/null 2>&1 )
cp "$D6/sessions.json" "$D6/before.json"; cp "$D6/sessions.log" "$D6/before.log"
out=$(SALA_SESSIONS=off SALA_SIDECAR="$D6/pane-map.tsv" "$SALA" sessions record o6 --transcript "$R2" --why clear 2>&1); rc=$?
[ "$rc" = 0 ] && same_file "$D6/sessions.json" "$D6/before.json" && same_file "$D6/sessions.log" "$D6/before.log" && ok "SALA_SESSIONS=off: record writes nothing and is not an error" || bad "off: rc=$rc $out"
( export SALA_SIDECAR="$D6/pane-map.tsv"; unset SALA_SESSIONS_FILE; . "$ROOT/lib/common.sh"; ( flock 6; sleep 3 ) 6>>"$SALA_SIDECAR.lock" & H=$!; sleep 0.5
  t0=$(date +%s); "$SALA" sessions record o6 --transcript "$R2" --why clear >/dev/null 2>&1; echo "$(( $(date +%s) - t0 ))" > "$HOME/rec.wait"; wait "$H"
  python3 "$HOME/regq.py" "$SALA_SESSIONS_FILE" o6 transcripts | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' > "$HOME/rec.n" )
[ "$(<"$HOME/rec.wait")" -ge 2 ] && [ "$(<"$HOME/rec.n")" = 2 ] && ok "record shares the pane map's lock: it waits for it, then lands ($(<"$HOME/rec.wait") s)" || bad "lock: waited $(<"$HOME/rec.wait"), transcripts $(<"$HOME/rec.n")"

echo "== phase 2: sessions prepare/abandon (what spawn calls)"
D7="$HOME/prep7"; mkdir -p "$D7"
( export SALA_SIDECAR="$D7/pane-map.tsv"; unset SALA_SESSIONS_FILE; . "$ROOT/lib/common.sh"
  P1=$(sessions_prepare p7 p7 /w/p7); P1b=$(sessions_prepare p7 p7 /w/p7)
  echo "$P1 $P1b" > "$HOME/prep.ids"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); r=list(d["sessions"].values()); print(len(r), r[0]["state"], len(r[0]["transcripts"]), r[0]["name"], r[0]["cwd"])' "$SALA_SESSIONS_FILE" > "$HOME/prep.row"
  ledger_write add p7 "$R1" p7 /w/p7 >/dev/null 2>&1
  sessions_abandon "$P1"; python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); r=list(d["sessions"].values()); print(len(r), r[0]["id"], len(r[0]["transcripts"]))' "$SALA_SESSIONS_FILE" > "$HOME/prep.kept"
  P2=$(sessions_prepare p8 p8 /w/p8); sessions_abandon "$P2"; python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d["sessions"]))' "$SALA_SESSIONS_FILE" > "$HOME/prep.gone" )
read -r PA PB < "$HOME/prep.ids"
[[ "$PA" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] && [ "$PA" = "$PB" ] && ok "prepare mints a uuid4 and a second prepare of the name returns the same live row" || bad "ids: $PA $PB"
[ "$(<"$HOME/prep.row")" = "1 live 0 p7 /w/p7" ] && ok "the prepared row is live, has no conversation yet, and has name and cwd" || bad "row: $(<"$HOME/prep.row")"
[ "$(<"$HOME/prep.kept")" = "1 $PA 1" ] && ok "the add that follows reuses the prepared row (same id, the conversation joins it); abandon keeps a row that has one" || bad "kept: $(<"$HOME/prep.kept") vs $PA"
[ "$(<"$HOME/prep.gone")" = 1 ] && ok "abandon drops a prepared row that never had a conversation" || bad "abandon: $(<"$HOME/prep.gone")"

echo "== phase 2: the SessionStart hook (salamander hook session-start)"
H1=22222222-0000-4000-8000-0000000000b1; H2=22222222-0000-4000-8000-0000000000b2; H3=22222222-0000-4000-8000-0000000000b3; H4=22222222-0000-4000-8000-0000000000b4
ledger_write add hook1 "$H1" hook1 "$HOME/wh" >/dev/null 2>&1
HID=$(q hook1 id | tr -d '"')
hookrun() {  # <source> <session id> [env…] → HOUT (stdout+stderr), HRC; the payload as Claude Code sends it
    local src="$1" sid="$2"; shift 2
    HOUT=$(printf '{"session_id":"%s","transcript_path":"/x/%s.jsonl","cwd":"/w","hook_event_name":"SessionStart","source":"%s"}' "$sid" "$sid" "$src" | env "$@" "$SALA" hook session-start 2>&1); HRC=$?
}
hookrun clear "$H2" SALA_SESSION_ID="$HID"
[ "$HRC" = 0 ] && [ -z "$HOUT" ] && [ "$(ntr hook1)" = "2 $H2:clear" ] && ok "source clear → why clear, appended to the row SALA_SESSION_ID names; exit 0, nothing printed" || bad "clear: rc=$HRC out='$HOUT' :: $(ntr hook1)"
hookrun resume "$H3" SALA_SESSION_ID="$HID"
[ "$HRC" = 0 ] && [ -z "$HOUT" ] && [ "$(ntr hook1)" = "3 $H2:clear $H3:resume" ] && ok "source resume → why resume" || bad "resume: rc=$HRC out='$HOUT' :: $(ntr hook1)"
hookrun startup "$H4" SALA_SESSION_ID="$HID"
[ "$HRC" = 0 ] && [ -z "$HOUT" ] && [ "$(ntr hook1)" = "4 $H2:clear $H3:resume $H4:start" ] && ok "source startup → why start" || bad "startup: rc=$HRC out='$HOUT' :: $(ntr hook1)"
cp "$REG" "$HOME/reg.before"
hookrun compact "22222222-0000-4000-8000-0000000000b5" SALA_SESSION_ID="$HID"; r1=$HRC; o1=$HOUT
hookrun other "22222222-0000-4000-8000-0000000000b6" SALA_SESSION_ID="$HID"; r2=$HRC; o2=$HOUT
hookrun clear "$H2" SALA_SESSION_ID="$HID"; r3=$HRC; o3=$HOUT
[ "$r1$r2$r3" = 000 ] && [ -z "$o1$o2$o3" ] && same_file "$REG" "$HOME/reg.before" && ok "compact and an unknown source record nothing; a repeated clear is a no-op; all exit 0 silently" || bad "compact/other/repeat: $r1$r2$r3 '$o1$o2$o3'"
hookrun clear "22222222-0000-4000-8000-0000000000b7" SALA_SESSION_ID="$HID" CLAUDE_CODE_ENTRYPOINT=sdk-cli
[ "$HRC" = 0 ] && [ -z "$HOUT" ] && same_file "$REG" "$HOME/reg.before" && ok "a headless claude -p (CLAUDE_CODE_ENTRYPOINT=sdk-cli) that inherited the id records nothing" || bad "sdk-cli: rc=$HRC '$HOUT'"
hookrun clear "22222222-0000-4000-8000-0000000000b8" SALA_SESSION_ID=00000000-0000-4000-8000-000000000000
[ "$HRC" = 0 ] && [ -z "$HOUT" ] && same_file "$REG" "$HOME/reg.before" && ok "an id the registry does not know: exit 0, nothing printed, nothing written" || bad "unknown id: rc=$HRC '$HOUT'"
hookrun clear "22222222-0000-4000-8000-0000000000b9" -u SALA_SESSION_ID -u TMUX_PANE
[ "$HRC" = 0 ] && [ -z "$HOUT" ] && same_file "$REG" "$HOME/reg.before" && ok "no SALA_SESSION_ID and no pane: nothing done, exit 0" || bad "no id: rc=$HRC '$HOUT'"
for junk in '' 'not json' '{' '[]' '"x"' '{"session_id":5,"source":"clear"}' '{"session_id":"../../x","source":"clear"}' '{"source":"clear"}' '{"session_id":"22222222-0000-4000-8000-0000000000ba"}' "$(printf '\377\376bad')"; do
    HOUT=$(printf '%s' "$junk" | SALA_SESSION_ID="$HID" "$SALA" hook session-start 2>&1); HRC=$?
    [ "$HRC" = 0 ] && [ -z "$HOUT" ] && same_file "$REG" "$HOME/reg.before" || bad "garbage '$junk': rc=$HRC out='$HOUT'"
done; ok "garbage on stdin (empty, text, truncated or wrong-typed JSON, a path in session_id, binary): exit 0, silent, nothing written"
HOUT=$(printf '{"session_id":"%s","source":"clear"}' "$H2" | SALA_SESSION_ID="$HID" SALA_BIN=/nonexistent/salamander "$SALA" hook session-start 2>&1); HRC=$?
[ "$HRC" = 0 ] && [ -z "$HOUT" ] && ok "even with the sala binary it calls missing: exit 0, silent" || bad "missing binary: rc=$HRC '$HOUT'"
HOUT=$(SALA_SESSION_ID="$HID" "$SALA" hook session-start </dev/null 2>&1); HRC=$?
[ "$HRC" = 0 ] && [ -z "$HOUT" ] && ok "empty stdin: exit 0, silent" || bad "empty stdin: rc=$HRC '$HOUT'"
D8="$HOME/hookoff8"; mkdir -p "$D8"
( export SALA_SIDECAR="$D8/pane-map.tsv" SALA_SESSIONS=write; unset SALA_SESSIONS_FILE; . "$ROOT/lib/common.sh"; ledger_write add h8 "$H1" h8 /w/h8 >/dev/null 2>&1; python3 -c 'import json,sys; print(list(json.load(open(sys.argv[1]))["sessions"])[0])' "$SALA_SESSIONS_FILE" > "$HOME/h8.id" )
cp "$D8/sessions.json" "$D8/before.json"
HOUT=$(printf '{"session_id":"%s","source":"clear"}' "$H2" | SALA_SESSIONS=off SALA_SIDECAR="$D8/pane-map.tsv" SALA_SESSION_ID="$(<"$HOME/h8.id")" "$SALA" hook session-start 2>&1); HRC=$?
[ "$HRC" = 0 ] && [ -z "$HOUT" ] && same_file "$D8/sessions.json" "$D8/before.json" && ok "SALA_SESSIONS=off: the hook writes nothing" || bad "hook off: rc=$HRC '$HOUT'"
# the fallback: no SALA_SESSION_ID, the row of the pane's tmux session name (a private server on this suite's socket)
tmux new-session -d -s hookpane 2>/dev/null
HP=$(tmux list-panes -t =hookpane -F '#{pane_id}' 2>/dev/null | head -1)
ledger_write add hookpane "$H1" hookpane "$HOME/wh" >/dev/null 2>&1
HOUT=$(printf '{"session_id":"%s","source":"clear"}' "$H2" | env -u SALA_SESSION_ID TMUX_PANE="$HP" "$SALA" hook session-start 2>&1); HRC=$?
[ "$HRC" = 0 ] && [ -z "$HOUT" ] && [ "$(ntr hookpane)" = "2 $H2:clear" ] && ok "no SALA_SESSION_ID: the row named like the pane's tmux session takes it" || bad "fallback: rc=$HRC '$HOUT' :: $(ntr hookpane)"
tmux kill-server 2>/dev/null

echo "== phase 3: the heartbeat publishes session-registry.json"
export PYTHONDONTWRITEBYTECODE=1
P3="$HOME/p3"; mkdir -p "$P3/live"
cat > "$P3/mk.py" <<'PY'
import json, sys
def row(i, name, state="live", project=None, role=None, aliases=(), tr=(), created="2026-10-20T00:00:00Z"):
    return {"id": i, "name": name, "project": project, "role": role, "lane": "subscription-1", "model": "opus", "effort": "high", "pane": name,
            "cwd": "/w/" + name, "machine": "q", "created": created, "state": state,
            "retired_at": "2026-10-21T01:00:00Z" if state == "retired" else None,
            "aliases": list(aliases), "transcripts": [{"id": t, "machine": "q", "at": created, "why": w} for t, w in tr]}
I = lambda n: "%08d-aaaa-4000-8000-%012d" % (n * 1111111, n)
rows = [
  row(I(1), "alpha", project="projects/salamander", role="back", aliases=["oldalpha"], tr=[("t-a1", "add"), ("t-a2", "clear")], created="2026-10-20T00:00:01Z"),
  row(I(2), "gone", "retired", aliases=["shared"], tr=[("t-g1", "add")], created="2026-10-20T00:00:02Z"),
  row(I(3), "shared", project="projects/salamander", role="front", tr=[("t-s1", "add")], created="2026-10-20T00:00:03Z"),
  row(I(4), "twin1", project="projects/p", role="x", created="2026-10-20T00:00:04Z"),
  row(I(5), "twin2", project="projects/p", role="x", created="2026-10-20T00:00:05Z"),
  row("99999999-aaaa-4000-8000-000000000008", "dupl", created="2026-10-20T00:00:06Z"),
  row("99999999-aaaa-4000-8000-000000000009", "dupl", created="2026-10-20T00:00:07Z"),
  row(I(10), "solo", "retired", project="projects/q", role="back", tr=[("t-x1", "add")], created="2026-10-20T00:00:08Z"),
  row(I(11), "forkA", tr=[("t-fork", "add")], created="2026-10-20T00:00:09Z"),
  row(I(12), "forkB", "retired", tr=[("t-fork", "import")], created="2026-10-20T00:00:10Z"),
]
json.dump({"schema": 1, "written": "2026-10-21T00:00:00Z", "sessions": {r["id"]: r for r in rows}}, open(sys.argv[1], "w"), indent=2)
print("\n".join("%s=%s" % (r["name"] + ("_r" if r["state"] == "retired" else ""), r["id"]) for r in rows))
PY
python3 "$P3/mk.py" "$P3/sessions.json" > "$P3/ids.txt"
idof() { sed -n "s/^$1=//p" "$P3/ids.txt"; }   # idof <name|name_r>
hb() { env SALA_SIDECAR="$P3/pane-map.tsv" SALA_HEARTBEAT_STATE_DIR="$P3/live" SALA_HEARTBEAT_LETTER=q SALA_HEARTBEAT_NAME=p3box "$@" "$SALA" heartbeat --no-push 2>&1; }
RJ="$P3/live/q/session-registry.json"; PLOG="$P3/sessions.log"
out=$(hb env SALA_SESSIONS=write); rc=$?
[ "$rc" = 0 ] && [ -s "$RJ" ] && ok "the heartbeat wrote session-registry.json beside machine.json and sessions.json" || bad "heartbeat rc=$rc: $out"
python3 - "$RJ" "$P3/sessions.json" "$P3/live/q/sessions.json" <<'PY' && ok "schema 1, machine, written (ISO Z), every row (retired too) keyed by its id with exactly the contract fields" || bad "contents off contract"
import json, re, sys
d = json.load(open(sys.argv[1])); src = json.load(open(sys.argv[2]))["sessions"]
assert d["schema"] == 1 and d["machine"] == "q" and re.match(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$", d["written"]), d
assert set(d) == {"schema", "machine", "written", "sessions"}, set(d)
assert set(d["sessions"]) == set(src) and len(src) == 10, "ids"
want = {"id", "name", "aliases", "project", "project_key", "role", "lane", "model", "effort", "pane", "cwd", "state", "created", "retired_at", "transcripts"}
for i, r in d["sessions"].items():
    assert set(r) == want, (r["name"], set(r) ^ want)
    s = src[i]
    for k in ("id", "name", "aliases", "project", "role", "lane", "model", "effort", "pane", "cwd", "state", "created", "retired_at"):
        assert r[k] == s[k], (r["name"], k)
    assert r["project_key"] == s["project"], "project_key is the page key until stackshot ids exist"
    assert [set(t) for t in r["transcripts"]] == [{"id", "machine", "at", "why"}] * len(s["transcripts"])
    assert [t["id"] for t in r["transcripts"]] == [t["id"] for t in s["transcripts"]]
a = [r for r in d["sessions"].values() if r["name"] == "alpha"][0]
assert a["aliases"] == ["oldalpha"] and a["project"] == "projects/salamander" and a["role"] == "back" and a["transcripts"][1]["why"] == "clear"
g = [r for r in d["sessions"].values() if r["name"] == "gone"][0]
assert g["state"] == "retired" and g["retired_at"] == "2026-10-21T01:00:00Z", "retired rows stay"
assert "schema" not in json.load(open(sys.argv[3])), "the reply-links sessions.json is not the registry"
PY
[ -z "$(ls "$P3/live/q" | grep '\.tmp$')" ] && [ -s "$P3/live/q/machine.json" ] && [ -f "$P3/live/q/sessions.json" ] && ok "no temp file left in the store directory (tmp + replace); machine.json and sessions.json are written as before" || bad "store dir: $(ls "$P3/live/q")"

echo "== phase 3: written is refreshed on every run, nothing else moves; a reader never sees a torn file"
cp "$RJ" "$P3/first.json"; sleep 1.2
cat > "$P3/reader.py" <<'PY'
import json, sys, time
end = time.time() + float(sys.argv[2]); n = bad = 0
while time.time() < end:
    try:
        d = json.load(open(sys.argv[1])); assert d["schema"] == 1 and len(d["sessions"]) == 10; n += 1
    except FileNotFoundError: pass
    except Exception: bad += 1
    time.sleep(0.0005)
print(n, bad)
PY
python3 "$P3/reader.py" "$RJ" 7 > "$P3/reader.out" &
RP=$!
out=$(hb env SALA_SESSIONS=write); sleep 1.2; out2=$(hb env SALA_SESSIONS=write); wait $RP
python3 - "$P3/first.json" "$RJ" <<'PY' && ok "no row changed, yet written moved forward on a later run; every other part of the document is the same" || bad "written not refreshed or other content moved"
import json, sys
a, b = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
assert b["written"] > a["written"], (a["written"], b["written"])
a.pop("written"); b.pop("written"); assert a == b
PY
read -r nreads nbad < "$P3/reader.out"
[ "${nbad:-1}" = 0 ] && [ "${nreads:-0}" -gt 100 ] && ok "a reader polling through two heartbeats never saw a missing, empty or half-written file ($nreads reads)" || bad "reader: ${nreads:-?} reads, ${nbad:-?} bad"
python3 - "$P3/sessions.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); r = next(v for v in d["sessions"].values() if v["name"] == "alpha")
r["role"] = "front"; r["transcripts"].append({"id": "t-a3", "machine": "q", "at": "2026-10-22T00:00:00Z", "why": "resume"}); json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
out=$(hb env SALA_SESSIONS=write)
python3 - "$RJ" <<'PY' && ok "a change in sessions.json (a role, a new conversation) is published on the next run" || bad "change not published"
import json, sys
d = json.load(open(sys.argv[1])); a = next(v for v in d["sessions"].values() if v["name"] == "alpha")
assert a["role"] == "front" and [t["id"] for t in a["transcripts"]] == ["t-a1", "t-a2", "t-a3"]
PY
python3 "$P3/mk.py" "$P3/sessions.json" >/dev/null   # the fixture as it was

echo "== phase 3: --dry-run prints the document and writes nothing; off, missing and corrupt publish nothing and keep the last good file"
D3="$P3/dry"; mkdir -p "$D3"
out=$(env SALA_SIDECAR="$P3/pane-map.tsv" SALA_HEARTBEAT_STATE_DIR="$D3" SALA_HEARTBEAT_LETTER=q SALA_HEARTBEAT_NAME=p3box "$SALA" heartbeat --dry-run 2>&1)
echo "$out" | grep -q '"schema": 1' && [ ! -e "$D3/q/session-registry.json" ] && ok "--dry-run shows the registry document and writes no file" || bad "dry-run: $(ls -R "$D3")"
O3="$P3/off"; mkdir -p "$O3"
out=$(env SALA_SIDECAR="$P3/pane-map.tsv" SALA_HEARTBEAT_STATE_DIR="$O3" SALA_HEARTBEAT_LETTER=q SALA_HEARTBEAT_NAME=p3box SALA_SESSIONS=off "$SALA" heartbeat --no-push 2>&1)
[ -s "$O3/q/machine.json" ] && [ ! -e "$O3/q/session-registry.json" ] && ok "SALA_SESSIONS=off: machine.json is written as before, session-registry.json is not" || bad "off: $(ls -R "$O3"); $out"
cp "$RJ" "$P3/good.json"; sleep 1.2
out=$(hb env SALA_SESSIONS=off)
same_file "$RJ" "$P3/good.json" && ok "off with a file already there: it is left exactly as it was (not deleted, not refreshed)" || bad "off touched the file"
cp "$P3/sessions.json" "$P3/sessions.good"; printf '{ this is not json' > "$P3/sessions.json"; cp "$P3/sessions.json" "$P3/sessions.bad"; : > "$PLOG"
out=$(hb env SALA_SESSIONS=write); rc=$?; sleep 1.1; out2=$(hb env SALA_SESSIONS=write)
same_file "$RJ" "$P3/good.json" && [ "$rc" = 0 ] && ok "a corrupt sessions.json: the heartbeat still succeeds and the last good session-registry.json stays byte for byte" || bad "corrupt: rc=$rc $out"
[ "$(grep -c "	heartbeat	" "$PLOG")" = 1 ] && grep -q "last good file stays" "$PLOG" && ok "exactly one log line in sessions.log for two runs on the same failure" || bad "log: $(slurp "$PLOG")"
same_file "$P3/sessions.json" "$P3/sessions.bad" && ok "the corrupt registry itself is never overwritten" || bad "corrupt file was changed"
rm -f "$P3/sessions.json"; : > "$PLOG"
out=$(hb env SALA_SESSIONS=write)
same_file "$RJ" "$P3/good.json" && [ "$(grep -c "	heartbeat	" "$PLOG")" = 1 ] && ok "a missing sessions.json: nothing published, last good file stays, one log line" || bad "missing: $(slurp "$PLOG")"
cp "$P3/sessions.good" "$P3/sessions.json"; sleep 1.1
out=$(hb env SALA_SESSIONS=write)
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["written"])' "$RJ")" != "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["written"])' "$P3/good.json")" ] && ok "the registry back: publishing resumes (written moves)" || bad "did not resume"
E3="$P3/empty"; mkdir -p "$E3"
out=$(env SALA_SIDECAR="$E3/pane-map.tsv" SALA_HEARTBEAT_STATE_DIR="$E3/live" SALA_HEARTBEAT_LETTER=q SALA_HEARTBEAT_NAME=p3box "$SALA" heartbeat --no-push 2>&1)
[ ! -e "$E3/live/q/session-registry.json" ] && [ -s "$E3/live/q/machine.json" ] && ok "a box with no sessions.json at all publishes no registry file (its other files are unaffected)" || bad "no registry: $(ls -R "$E3")"

echo "== phase 3: sala sessions resolve"
cp "$P3/sessions.json" "$P3/reg.pristine"; : > "$PLOG"
res() { RES=$(env SALA_SIDECAR="$P3/pane-map.tsv" "$SALA" sessions resolve "$@" 2>"$P3/res.err"); RRC=$?; RERR=$(<"$P3/res.err"); }
AID=$(idof alpha); GONE=$(idof gone_r); SHD=$(idof shared); T1=$(idof twin1); T2=$(idof twin2)
res "$AID"
[ "$RRC" = 0 ] && echo "$RES" | grep -q "^id: *$AID$" && echo "$RES" | grep -q "^name: *alpha$" && echo "$RES" | grep -q "^state: *live$" && echo "$RES" | grep -q "^project: *projects/salamander$" && echo "$RES" | grep -q "^role: *back$" && echo "$RES" | grep -q "^pane: *alpha$" && ok "a full session id: id, name, state, project, role and pane" || bad "by id: rc=$RRC $RES"
res "${AID:0:8}"; [ "$RRC" = 0 ] && echo "$RES" | grep -q "^id: *$AID$" && ok "a unique prefix of 8 characters" || bad "prefix: rc=$RRC $RES $RERR"
res "${AID:0:7}"; [ "$RRC" = 1 ] && ok "7 characters are not a prefix (exit 1)" || bad "7 chars: rc=$RRC $RES"
res t-a2; [ "$RRC" = 0 ] && echo "$RES" | grep -q "^name: *alpha$" && ok "a transcript id (a non-first one) finds its session" || bad "transcript: rc=$RRC $RES"
res alpha; [ "$RRC" = 0 ] && echo "$RES" | grep -q "^id: *$AID$" && ok "a name" || bad "name: rc=$RRC $RES"
res oldalpha; [ "$RRC" = 0 ] && echo "$RES" | grep -q "^id: *$AID$" && ok "an alias (an old name)" || bad "alias: rc=$RRC $RES"
res role:projects/salamander/back; [ "$RRC" = 0 ] && echo "$RES" | grep -q "^id: *$AID$" && ok "role:<project>/<role> with one live row" || bad "role: rc=$RRC $RES $RERR"
res --json alpha; [ "$RRC" = 0 ] && echo "$RES" | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["name"]=="alpha" and len(r["transcripts"])==2' && ok "--json prints the row" || bad "json: $RES"
res nosuchname; [ "$RRC" = 1 ] && [ -z "$RES" ] && [ -n "$RERR" ] && ok "no match: exit 1, the reason on stderr" || bad "none: rc=$RRC '$RES' '$RERR'"
res role:projects/none/back; [ "$RRC" = 1 ] && ok "role: with no live row: exit 1" || bad "role none: rc=$RRC $RES"
res role:badform; [ "$RRC" = 1 ] && ok "a malformed role: ref: exit 1" || bad "role form: rc=$RRC"
res role:projects/p/x; [ "$RRC" = 2 ] && echo "$RERR" | grep -q ambiguous && echo "$RERR" | grep -q "$T1" && echo "$RERR" | grep -q "$T2" && [ -z "$RES" ] && ok "role: with two live rows: exit 2, 'ambiguous', both ids listed, nothing picked" || bad "role ambiguous: rc=$RRC '$RES' '$RERR'"
res role:projects/q/back; [ "$RRC" = 1 ] && ok "role: looks at live rows only (the retired solo does not fill it)" || bad "role retired: rc=$RRC $RES"
echo "-- retired rows: resolve, marked, unless --live"
res solo; [ "$RRC" = 0 ] && echo "$RES" | grep -q "^state: *retired" && ok "a retired row resolves and says retired" || bad "retired: rc=$RRC $RES"
res --live solo; [ "$RRC" = 1 ] && ok "--live: the retired row does not resolve (exit 1)" || bad "retired --live: rc=$RRC $RES"
res "$GONE"; [ "$RRC" = 0 ] && echo "$RES" | grep -q "retired" && ok "a retired row by its id resolves" || bad "retired id: rc=$RRC"
res --live "$GONE"; [ "$RRC" = 1 ] && ok "--live by a retired id: none" || bad "retired id --live: rc=$RRC"
res t-g1; [ "$RRC" = 0 ] && echo "$RES" | grep -q "^name: *gone$" && ok "a retired row's transcript resolves" || bad "retired transcript: rc=$RRC"
echo "-- ambiguity is never resolved silently (names, aliases, transcripts, prefixes)"
res shared
[ "$RRC" = 2 ] && [ -z "$RES" ] && echo "$RERR" | grep -q ambiguous && echo "$RERR" | grep -q "$GONE" && echo "$RERR" | grep -q "$SHD" && ok "a retired row's old name (alias) reused by a live row: exit 2, 'ambiguous', both ids listed" || bad "shared: rc=$RRC '$RES' '$RERR'"
res --live shared; [ "$RRC" = 0 ] && echo "$RES" | grep -q "^id: *$SHD$" && ok "--live picks the live one, and only --live does" || bad "shared --live: rc=$RRC $RES $RERR"
res --json shared; [ "$RRC" = 2 ] && echo "$RES" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["error"]=="ambiguous" and len(d["candidates"])==2' && ok "--json: exit 2 and an ambiguous object with the candidate ids" || bad "json ambiguous: rc=$RRC $RES"
res dupl; [ "$RRC" = 2 ] && echo "$RERR" | grep -q "99999999-aaaa-4000-8000-000000000008" && echo "$RERR" | grep -q "99999999-aaaa-4000-8000-000000000009" && ok "two rows with the same name: exit 2 with both ids" || bad "dupl: rc=$RRC $RERR"
res --live dupl; [ "$RRC" = 2 ] && ok "--live does not break a tie between two live rows (still exit 2)" || bad "dupl --live: rc=$RRC"
res 99999999; [ "$RRC" = 2 ] && echo "$RERR" | grep -q ambiguous && ok "an id prefix on two rows: exit 2" || bad "prefix ambiguous: rc=$RRC"
res t-fork; [ "$RRC" = 2 ] && echo "$RERR" | grep -q "$(idof forkA)" && echo "$RERR" | grep -q "$(idof forkB_r)" && ok "a transcript listed by two rows: exit 2, both ids" || bad "transcript ambiguous: rc=$RRC $RERR"
res --live t-fork; [ "$RRC" = 0 ] && echo "$RES" | grep -q "^name: *forkA$" && ok "--live narrows a shared transcript to the live row" || bad "fork --live: rc=$RRC $RES"
python3 - "$ROOT" "$P3/sessions.json" <<'PY' && ok "lib/sessions.py resolve(): the same lookup as a python function (rows found; Unresolved with .kind and .candidates)" || bad "python resolve()"
import json, sys
sys.path.insert(0, sys.argv[1] + "/lib")
import sessions as S
rows = json.load(open(sys.argv[2]))["sessions"]
assert S.resolve(rows, "oldalpha")["name"] == "alpha"
assert S.resolve(rows, "shared", live_only=True)["name"] == "shared"
for ref, kind, n in (("shared", "ambiguous", 2), ("dupl", "ambiguous", 2), ("nope", "none", 0), ("role:projects/p/x", "ambiguous", 2)):
    try: S.resolve(rows, ref); raise SystemExit("no error for " + ref)
    except S.Unresolved as u: assert u.kind == kind and len(u.candidates) == n, (ref, u.kind, len(u.candidates))
PY
echo "-- read-only"
same_file "$P3/sessions.json" "$P3/reg.pristine" && [ ! -s "$PLOG" ] && [ ! -d "$P3/sessions-history" ] && ok "after all those lookups sessions.json is byte-identical and sessions.log is empty (nothing written)" || bad "resolve wrote something"
printf 'not json' > "$P3/sessions.json"
res alpha; [ "$RRC" = 1 ] && [ -n "$RERR" ] && [ "$(<"$P3/sessions.json")" = "not json" ] && [ ! -s "$PLOG" ] && ok "a corrupt registry: exit 1 with the reason, the file untouched, no log line" || bad "corrupt resolve: rc=$RRC '$RERR'"
rm -f "$P3/sessions.json"; res alpha; [ "$RRC" = 1 ] && [ ! -e "$P3/sessions.json" ] && ok "no registry file: exit 1, nothing created" || bad "missing resolve: rc=$RRC"
cp "$P3/reg.pristine" "$P3/sessions.json"
RES=$(env SALA_SESSIONS=off SALA_SIDECAR="$P3/pane-map.tsv" "$SALA" sessions resolve alpha 2>&1); [ $? = 0 ] && ok "SALA_SESSIONS=off: the resolver still reads" || bad "off resolve: $RES"
RES=$("$SALA" sessions resolve 2>&1); [ $? -ne 0 ] && ok "no ref: a usage error" || bad "no ref: $RES"
echo "-- sessions transcript: where a session's conversations are on disk, read-only"
mkdir -p "$HOME/.claude/projects/x" "$HOME/.claude/projects/y"; echo '{}' > "$HOME/.claude/projects/x/t-a2.jsonl"; echo '{}' > "$HOME/.claude/projects/y/t-g1.jsonl"
tres() { RES=$(env SALA_SIDECAR="$P3/pane-map.tsv" "$SALA" sessions transcript "$@" 2>"$P3/res.err"); RRC=$?; RERR=$(<"$P3/res.err"); }
tres alpha
[ "$RRC" = 0 ] && [ "$(sed -n 1p <<< "$RES")" = "alpha ($(idof alpha | cut -c1-8), live): 2 conversations" ] && [ "$(sed -n 2p <<< "$RES" | awk '{print $1, $2}')" = "current $HOME/.claude/projects/x/t-a2.jsonl" ] \
    && sed -n 3p <<< "$RES" | grep -q "^earlier  (not on this box)" && ok "the current conversation first with its file, the earlier one after it (its file not on this box, said so)" || bad "transcript alpha: rc=$RRC $RES $RERR"
tres --json alpha
echo "$RES" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["name"] == "alpha" and d["state"] == "live" and [t["id"] for t in d["transcripts"]] == ["t-a2", "t-a1"], d
assert d["transcripts"][0]["current"] is True and d["transcripts"][0]["path"].endswith("/x/t-a2.jsonl") and d["transcripts"][0]["why"] == "clear", d
assert d["transcripts"][1]["current"] is False and d["transcripts"][1]["path"] is None, d' && ok "--json: id, name, state and the transcripts newest first, path null where the file is not here" || bad "transcript json: rc=$RRC $RES"
tres gone; [ "$RRC" = 0 ] && sed -n 2p <<< "$RES" | grep -q "^current  $HOME/.claude/projects/y/t-g1.jsonl" && ok "a retired session's transcript is found too" || bad "transcript retired: rc=$RRC $RES $RERR"
tres shared; [ "$RRC" = 0 ] && sed -n 1p <<< "$RES" | grep -q "^shared (.*, live)" && ok "a name a retired row also carries: the live row wins" || bad "transcript shared: rc=$RRC $RES $RERR"
tres dupl; [ "$RRC" = 2 ] && [ -z "$RES" ] && echo "$RERR" | grep -q ambiguous && ok "two live rows of a name: exit 2, never a pick" || bad "transcript dupl: rc=$RRC $RES $RERR"
tres nope; [ "$RRC" = 1 ] && ok "no such session: exit 1" || bad "transcript nope: rc=$RRC $RES $RERR"
RES=$("$SALA" sessions transcript 2>&1); [ $? -ne 0 ] && ok "no ref: a usage error" || bad "transcript no ref: $RES"
same_file "$P3/sessions.json" "$P3/reg.pristine" && [ ! -s "$PLOG" ] && ok "read-only: sessions.json byte-identical, sessions.log empty" || bad "transcript wrote something"

echo "== phase 4: sessions tag fills project and role of an existing live row"
G1=22222222-0000-4000-8000-0000000000b1; G2=22222222-0000-4000-8000-0000000000b2; G3=22222222-0000-4000-8000-0000000000b3
ledger_write add tagm "$G1" tagm "$HOME/wt1" >/dev/null 2>&1; ledger_write add tage "$G2" tage "$HOME/wt2" >/dev/null 2>&1; ledger_write add tagr "$G3" tagr "$HOME/wt3" >/dev/null 2>&1
TID=$(q tagm id | tr -d '"'); EID=$(q tage id | tr -d '"')
cp "$REG" "$HOME/reg.before"; : > "$RLOG"
out=$("$SALA" sessions tag tagm --project projects/general --role front --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q "would tag" && same_file "$REG" "$HOME/reg.before" && [ ! -s "$RLOG" ] && ok "--dry-run says what it would set and writes nothing (file and log unchanged)" || bad "dry run: rc=$rc $out"
out=$("$SALA" sessions tag tagm --project projects/general --role front 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(q tagm project)" = '"projects/general"' ] && [ "$(q tagm role)" = '"front"' ] && ok "by name: project and role are set" || bad "tag by name: rc=$rc $out :: $(q tagm project) $(q tagm role)"
[ "$(q tagm name)" = '"tagm"' ] && [ "$(q tagm id | tr -d '"')" = "$TID" ] && [ "$(q tagm state)" = '"live"' ] && [ "$(q tagm pane)" = '"tagm"' ] && [ "$(q tagm lane)" = null ] && [ "$(q tagm transcripts | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" = 1 ] && ok "no other field of the row changed" || bad "other fields: $(<"$REG")"
grep -q "$(printf 'tag\ttagm\t%s' "$TID")" "$RLOG" && ok "sessions.log has a tag line naming the row" || bad "log: $(<"$RLOG")"
ls "$SALA_SESSIONS_HISTORY" 2>/dev/null | grep -q . && ok "the write went the registry's way: the previous file kept in sessions-history/" || bad "no history copy"
res2() { RES=$("$SALA" sessions resolve "$@" 2>"$HOME/res2.err"); RRC=$?; RERR=$(<"$HOME/res2.err"); }
res2 role:projects/general/front; [ "$RRC" = 0 ] && echo "$RES" | grep -q "^id: *$TID$" && ok "resolve role:projects/general/front finds it afterwards" || bad "resolve: rc=$RRC $RES $RERR"
out=$("$SALA" sessions tag "${EID:0:8}" --role back 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(q tage role)" = '"back"' ] && [ "$(q tage project)" = null ] && ok "by the 8-character id prefix; only --role given: project stays empty" || bad "by prefix: rc=$rc $out"
out=$("$SALA" sessions tag "$EID" --project-key projects/general 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(q tage project)" = '"projects/general"' ] && [ "$(q tage role)" = '"back"' ] && ok "by id, --project-key sets the row's project (project_key is derived from it); role kept" || bad "project-key: rc=$rc $out"
res2 role:projects/general/back; [ "$RRC" = 0 ] && echo "$RES" | grep -q "^id: *$EID$" && ok "resolve role:projects/general/back finds the second row" || bad "resolve back: rc=$RRC $RES $RERR"
python3 - "$ROOT" "$REG" <<'PY' && ok "the published copy carries project_key equal to the tagged project" || bad "export_doc project_key"
import sys
sys.path.insert(0, sys.argv[1] + "/lib")
import sessions as S
d = S.export_doc(sys.argv[2], "a", "2026-01-01T00:00:00Z")["sessions"]
r = [x for x in d.values() if x["name"] == "tage"][0]
assert r["project"] == "projects/general" and r["project_key"] == "projects/general" and r["role"] == "back"
PY
cp "$REG" "$HOME/reg.before"
out=$("$SALA" sessions tag tagm --project projects/general --role front 2>&1); rc=$?
[ "$rc" = 0 ] && same_file "$REG" "$HOME/reg.before" && ok "tagging what the row already has changes nothing (byte-identical)" || bad "repeat: rc=$rc $out"
out=$("$SALA" sessions tag tagm --role back 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(q tagm role)" = '"back"' ] && [ "$(q tagm project)" = '"projects/general"' ] && echo "$out" | grep -q "also fills" && ok "a second live row for the same role: set, with a note that resolve is now ambiguous" || bad "dup role: rc=$rc $out"
res2 role:projects/general/back; [ "$RRC" = 2 ] && ok "and resolve says ambiguous (exit 2), as it does for any ambiguity" || bad "dup resolve: rc=$RRC"
cp "$REG" "$HOME/reg.before"; : > "$RLOG"
for badargs in "tagm --role middle" "tagm --role FRONT" "tagm --role" "tagm --project 'a b'" "tagm --project a --project-key b" "tagm" "tagm --dry-run" "--role front" "tagm tage --role front" "tagm --bogus x"; do
    out=$(eval "\"\$SALA\" sessions tag $badargs" 2>&1); rc=$?
    [ "$rc" != 0 ] && [ -n "$out" ] && same_file "$REG" "$HOME/reg.before" && ok "bad arguments ($badargs): refused with a reason, nothing written" || bad "args '$badargs': rc=$rc $out"
done
out=$("$SALA" sessions tag --project x/y --role front 2>&1); rc=$?
[ "$rc" != 0 ] && same_file "$REG" "$HOME/reg.before" && ok "no session given: refused" || bad "no session: rc=$rc $out"
for who in nosuchname 00000000-0000-4000-8000-ffffffffffff deadbeef; do
    out=$("$SALA" sessions tag $who --role front 2>&1); rc=$?
    [ "$rc" != 0 ] && echo "$out" | grep -q "no session" && same_file "$REG" "$HOME/reg.before" && ok "unknown session '$who': clear error, non-zero, nothing written" || bad "unknown '$who': rc=$rc $out"
done
out=$("$SALA" sessions tag zzzzzzzz --role front --dry-run 2>&1); rc=$?
[ "$rc" != 0 ] && echo "$out" | grep -q "no session" && ok "--dry-run on an unknown session fails the same way" || bad "dry unknown: rc=$rc $out"
RGID=$(q tagr id | tr -d '"')
ledger_write retire tagr >/dev/null 2>&1; cp "$REG" "$HOME/reg.before"
out=$("$SALA" sessions tag tagr --role front 2>&1); rc=$?
[ "$rc" != 0 ] && echo "$out" | grep -q "no session" && same_file "$REG" "$HOME/reg.before" && ok "a retired session's name no longer resolves: refused, nothing written" || bad "retired by name: rc=$rc $out"
out=$("$SALA" sessions tag "$RGID" --role front 2>&1); rc=$?
[ "$rc" != 0 ] && echo "$out" | grep -q "retired" && same_file "$REG" "$HOME/reg.before" && ok "a retired row by its id: refused as retired, nothing written" || bad "retired by id: rc=$rc $out"
printf 'not json' > "$HOME/corrupt.json"; D7="$HOME/tag7"; mkdir -p "$D7"; cp "$HOME/corrupt.json" "$D7/sessions.json"
out=$(SALA_SIDECAR="$D7/pane-map.tsv" "$SALA" sessions tag tagm --role front 2>&1); rc=$?
[ "$rc" != 0 ] && [ "$(<"$D7/sessions.json")" = "not json" ] && ok "a corrupt registry is never overwritten by tag" || bad "corrupt: rc=$rc $out"
cp "$REG" "$HOME/reg.before"
out=$(SALA_SESSIONS=off "$SALA" sessions tag tage --role front 2>&1); rc=$?
[ "$rc" != 0 ] && echo "$out" | grep -q "SALA_SESSIONS=off" && same_file "$REG" "$HOME/reg.before" && ok "SALA_SESSIONS=off: tag refuses and says so, nothing written" || bad "off: rc=$rc $out"
( flock 6; sleep 3 ) 6>>"$MAP.lock" & H=$!; sleep 0.5
t0=$(date +%s); out=$("$SALA" sessions tag tage --role front 2>&1); rc=$?; t1=$(date +%s); wait "$H"
[ "$rc" = 0 ] && [ "$((t1 - t0))" -ge 2 ] && [ "$(q tage role)" = '"front"' ] && ok "tag waits for the pane map's lock, then lands ($((t1 - t0)) s)" || bad "lock: rc=$rc $((t1 - t0)) s $out"

[ "$fail" = 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
