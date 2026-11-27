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
# SURFACE (the end of this file): the registry row's optional `surface` (absent = sala, slack the only other value): `tag --surface`, `tag --auto` copying or clearing it from
# the project record, `set`, the listings (`[slack]`, JSON only when slack), `slack-names`, the publish, and a bad value refused wherever it is read.
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
cleanup() { command tmux -L "$SOCK-other" -f /dev/null kill-server 2>/dev/null; tmux_socket_rm "$SOCK-other"; tmux_socket_rm; rm -rf "$HOME" 2>/dev/null; true; }; trap cleanup EXIT
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
out=$("$SALA" sessions 2>&1)
grep -q "^plain (live, no lane, model, project, role or alias; --full lists every row with its id): delta$" <<< "$out" && ! grep -qE '^[0-9a-f]{8} +delta ' <<< "$out" && grep -qE '^[0-9a-f]{8} +gamma ' <<< "$out" && ok "the listing folds a row with nothing but its name into one plain line; gamma (a lane, a project) keeps its row" || bad "plain fold: $out"
out=$("$SALA" sessions --full 2>&1); grep -qE '^[0-9a-f]{8} +delta ' <<< "$out" && ! grep -q '^plain (' <<< "$out" && ok "--full: every row, with its id, no plain line" || bad "--full: $out"
out=$("$SALA" sessions --json 2>&1); python3 -c 'import json,sys; d=json.load(sys.stdin); assert "delta" in [r["name"] for r in d["sessions"]]' <<< "$out" && ok "--json always carries the plain rows" || bad "--json plain: $out"
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
tmux new-session -d -s hook1 2>/dev/null     # the row's own pane: a claude there is the session; HOOK_PANE is the pane the hook's claude is in (hookrun)
HOOK_PANE=$(tmux list-panes -t =hook1: -F '#{pane_id}' 2>/dev/null | head -1)
hookrun() {  # <source> <session id> [env…] → HOUT (stdout+stderr), HRC; the payload as Claude Code sends it, from the claude in $HOOK_PANE
    local src="$1" sid="$2"; shift 2
    HOUT=$(printf '{"session_id":"%s","transcript_path":"/x/%s.jsonl","cwd":"/w","hook_event_name":"SessionStart","source":"%s"}' "$sid" "$sid" "$src" | TMUX_PANE="$HOOK_PANE" env "$@" "$SALA" hook session-start 2>&1); HRC=$?
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
HOUT=$(printf '{"session_id":"%s","source":"clear"}' "$H2" | TMUX_PANE="$HOOK_PANE" SALA_SESSION_ID="$HID" SALA_BIN=/nonexistent/salamander "$SALA" hook session-start 2>&1); HRC=$?
[ "$HRC" = 0 ] && [ -z "$HOUT" ] && ok "even with the sala binary it calls missing: exit 0, silent" || bad "missing binary: rc=$HRC '$HOUT'"
HOUT=$(TMUX_PANE="$HOOK_PANE" SALA_SESSION_ID="$HID" "$SALA" hook session-start </dev/null 2>&1); HRC=$?
[ "$HRC" = 0 ] && [ -z "$HOUT" ] && ok "empty stdin: exit 0, silent" || bad "empty stdin: rc=$HRC '$HOUT'"
D8="$HOME/hookoff8"; mkdir -p "$D8"
( export SALA_SIDECAR="$D8/pane-map.tsv" SALA_SESSIONS=write; unset SALA_SESSIONS_FILE; . "$ROOT/lib/common.sh"; ledger_write add h8 "$H1" h8 /w/h8 >/dev/null 2>&1; python3 -c 'import json,sys; print(list(json.load(open(sys.argv[1]))["sessions"])[0])' "$SALA_SESSIONS_FILE" > "$HOME/h8.id" )
cp "$D8/sessions.json" "$D8/before.json"
HOUT=$(printf '{"session_id":"%s","source":"clear"}' "$H2" | TMUX_PANE="$HOOK_PANE" SALA_SESSIONS=off SALA_SIDECAR="$D8/pane-map.tsv" SALA_SESSION_ID="$(<"$HOME/h8.id")" "$SALA" hook session-start 2>&1); HRC=$?
[ "$HRC" = 0 ] && [ -z "$HOUT" ] && same_file "$D8/sessions.json" "$D8/before.json" && ok "SALA_SESSIONS=off: the hook writes nothing" || bad "hook off: rc=$HRC '$HOUT'"
# the fallback: no SALA_SESSION_ID, the row of the pane's tmux session name (a private server on this suite's socket)
tmux new-session -d -s hookpane 2>/dev/null
HP=$(tmux list-panes -t =hookpane -F '#{pane_id}' 2>/dev/null | head -1)
ledger_write add hookpane "$H1" hookpane "$HOME/wh" >/dev/null 2>&1
HOUT=$(printf '{"session_id":"%s","source":"clear"}' "$H2" | env -u SALA_SESSION_ID TMUX_PANE="$HP" "$SALA" hook session-start 2>&1); HRC=$?
[ "$HRC" = 0 ] && [ -z "$HOUT" ] && [ "$(ntr hookpane)" = "2 $H2:clear" ] && ok "no SALA_SESSION_ID: the row named like the pane's tmux session takes it" || bad "fallback: rc=$HRC '$HOUT' :: $(ntr hookpane)"

echo "== phase 2: the hook records only for the claude in the row's own pane (SALA_SESSION_ID is inherited by every claude started from the pane's shell)"
# A throwaway `claude` on a private tmux server, in another tmux session, in another pane or window of the row's session, or with no tmux at all
# inherits SALA_SESSION_ID and must name no row. The row hook1 (pane $HOOK_PANE) is the one at stake; sessions.log gets one line per refusal.
SLOG="$SALA_SESSIONS_LOG"; nref() { grep -c "hook session-start: conversation .* not recorded on row" "$SLOG" 2>/dev/null || true; }
HN=3072; huid() { HN=$((HN+1)); printf -v CID "22222222-0000-4000-8000-%012x" "$HN"; }   # a fresh conversation id per check, in CID (no subshell: the counter must advance)
tmux new-session -d -s hookother 2>/dev/null; HPO=$(tmux list-panes -t =hookother: -F '#{pane_id}' | head -1)
tmux split-window -d -t =hook1: 2>/dev/null; HPS=$(tmux list-panes -t =hook1: -F '#{pane_id}' | tail -1)    # a second pane of the row's window
tmux new-window -d -t =hook1: 2>/dev/null; HPW=$(tmux list-panes -s -t =hook1 -F '#{pane_id}' | tail -1)    # a second window of the row's session (not the active one)
cp "$REG" "$HOME/reg.own"; ref0=$(nref)
refused() {  # <label> <source> <conversation id> [hookrun env…] → ok when exit 0, silent, nothing written
    local label="$1" src="$2" cid="$3"; shift 3
    hookrun "$src" "$cid" SALA_SESSION_ID="$HID" "$@"
    [ "$HRC" = 0 ] && [ -z "$HOUT" ] && same_file "$REG" "$HOME/reg.own" && ok "$label: not recorded, exit 0, silent" || bad "$label: rc=$HRC out='$HOUT' $(ntr hook1)"
}
# a throwaway on a private tmux server: its TMUX names that server, and its pane id can be the very id of the row's pane
PSOCK="$SOCK-other"; PT() { command tmux -L "$PSOCK" -f /dev/null "$@"; }
PT new-session -d -s throw 2>/dev/null; PP=$(PT list-panes -t =throw: -F '#{pane_id}' | head -1); k=0
while [ "$PP" != "$HOOK_PANE" ] && [ "$k" -lt 40 ]; do PT new-session -d -s "throw$k" 2>/dev/null; PP=$(PT list-panes -t "=throw$k:" -F '#{pane_id}' | head -1); k=$((k+1)); done
PTMUX="$(PT display -p '#{socket_path}'),$(PT display -p '#{pid}'),0"
[ "$PP" = "$HOOK_PANE" ] && ok "setup: a pane on the private server has the row's pane id ($HOOK_PANE)" || bad "setup: private pane $PP never matched $HOOK_PANE"
for src in clear resume startup; do
    huid; ( unset -f tmux; refused "a claude on a private tmux server (the row's pane id there), source $src" "$src" "$CID" TMUX_PANE="$PP" TMUX="$PTMUX" )
done
huid; refused "the fleet server, another tmux session" clear "$CID" TMUX_PANE="$HPO"
huid; refused "the fleet server, a second pane of the row's window" clear "$CID" TMUX_PANE="$HPS"
huid; refused "the fleet server, a second window of the row's session" clear "$CID" TMUX_PANE="$HPW"
huid; refused "a pane id the server does not have" clear "$CID" TMUX_PANE=%99999
huid; refused "no tmux at all (no TMUX_PANE)" clear "$CID" TMUX_PANE=
huid; refused "no tmux at all, source startup" startup "$CID" TMUX_PANE= TMUX=
[ "$(( $(nref) - ref0 ))" = 9 ] && ok "each refusal is one line in sessions.log" || bad "log lines: $(( $(nref) - ref0 )) of 9: $(tail -3 "$SLOG")"
huid; hookrun clear "$CID" SALA_SESSION_ID=00000000-0000-4000-8000-000000000000
[ "$HRC" = 0 ] && [ -z "$HOUT" ] && same_file "$REG" "$HOME/reg.own" && ok "an id that is no live row, from a pane: nothing recorded" || bad "unknown id: rc=$HRC '$HOUT'"
for src in clear resume startup; do   # the row's own pane, every source: recorded as before
    case $src in clear) w=clear ;; resume) w=resume ;; startup) w=start ;; esac
    huid; cid=$CID; hookrun "$src" "$cid" SALA_SESSION_ID="$HID"
    [ "$HRC" = 0 ] && [ -z "$HOUT" ] && [ "$(ntr hook1 | grep -cE " $cid:$w( |\$)")" = 1 ] && ok "the row's own pane (with a second pane and window beside it), source $src: recorded as $w" || bad "own pane $src: rc=$HRC '$HOUT' :: $(ntr hook1)"
done
PT kill-server 2>/dev/null; tmux_socket_rm "$PSOCK"
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

echo "== phase 5: sessions tag --auto gives a row with no role its project and role from the project record"
# the record (stackshot's projects.json, schema 1): proj-a lists ba (background), fa, tw, mm and dd (front), ex and late (background);
# proj-b lists dd too (so dd is on two maps); proj-old is retired and lists gone. The rows below are the registry's.
REC="$HOME/projects.json"
mkrec() {  # <generated ISO Z> [schema] → the record file
    python3 - "$REC" "$1" "${2:-1}" <<'PY'
import json, sys
path, gen, schema = sys.argv[1], sys.argv[2], int(sys.argv[3])
ag = lambda front: {"front": front, "role": "x", "mandate_line": "m"}
json.dump({"schema": schema, "generated": gen, "by_key": {}, "projects": {
    "prj_t1": {"id": "prj_t1", "key": "projects/proj-a", "retired": False, "agents": {"ba": ag(False), "fa": ag(True), "tw": ag(True), "mm": ag(True), "dd": ag(True), "ex": ag(False)}},
    "prj_t2": {"id": "prj_t2", "key": "projects/proj-b", "retired": False, "agents": {"dd": ag(False)}},
    "prj_t3": {"id": "prj_t3", "key": "projects/proj-old", "retired": True, "agents": {"gone": ag(False)}}}}, open(path, "w"))
PY
}
addrec() {  # <name> <front true|false> → the name joins proj-a's agents map
    python3 - "$REC" "$1" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["projects"]["prj_t1"]["agents"][sys.argv[2]] = {"front": sys.argv[3] == "true", "role": "x", "mandate_line": "m"}; json.dump(d, open(sys.argv[1], "w"))
PY
}
isonow() { date -u +%Y-%m-%dT%H:%M:%SZ; }
export SALA_PROJECT_RECORD="$REC"
i=0
for n in ba fa nl tw dd mm ex gone ro sd; do i=$((i + 1)); ledger_write add "$n" "44444444-0000-4000-8000-0000000000$(printf %02d $i)" "$n" "$HOME/wa-$n" >/dev/null 2>&1; done
"$SALA" sessions tag ro --role front >/dev/null 2>&1                                  # ro has a role already: front, though the record will list it as back
sessions_set tw throwaway=1 spawned_by=somebody >/dev/null 2>&1                       # tw is a bare spawn's row that the record lists
sessions_set sd side=1 >/dev/null 2>&1                                                # sd is a side session
sessions_set mm project=projects/elsewhere >/dev/null 2>&1                            # mm says another project than the record does
ledger_write retire ex >/dev/null 2>&1                                                # ex is listed, but retired
mkrec "$(isonow)"; addrec ro false
cp "$REG" "$HOME/reg.before"; : > "$RLOG"
out=$("$SALA" sessions tag --auto --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q "would tag ba .*project None -> projects/proj-a; role None -> back" && echo "$out" | grep -q "would tag fa .*role None -> front" && same_file "$REG" "$HOME/reg.before" && [ ! -s "$RLOG" ] && ok "--auto --dry-run says what it would write and writes nothing (file and log unchanged)" || bad "auto dry run: rc=$rc $out"
echo "$out" | grep -q "left nl .*on no project's agents map" && echo "$out" | grep -q "left sd .*side session" && echo "$out" | grep -q "left dd .*several projects" && echo "$out" | grep -q "left mm .*projects/elsewhere" && echo "$out" | grep -q "left gone .*no project" && ok "a row the record does not list, a side session, a name on two maps, a row of another project and a retired project's agent are left, each with its reason" || bad "left lines: $out"
echo "$out" | grep -q " ro (" && bad "a row that has a role is not looked at: $out" || ok "a row with a role is not listed at all"
out=$("$SALA" sessions tag --auto 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(q ba role)" = '"back"' ] && [ "$(q ba project)" = '"projects/proj-a"' ] && [ "$(q fa role)" = '"front"' ] && [ "$(q tw role)" = '"front"' ] && ok "--auto writes project and role (ba back, fa and tw front)" || bad "auto: rc=$rc $out :: $(q ba role) $(q fa role) $(q tw role)"
[ "$(q tw throwaway)" = null ] && ok "a listed row that was tagged throwaway stops being one" || bad "throwaway: $(q tw throwaway)"
[ "$(q ro role)" = '"front"' ] && [ "$(q ro project)" = null ] && ok "a role already on a row is never overwritten (ro stays front although the record says back)" || bad "ro: $(q ro role) $(q ro project)"
[ "$(q nl role)" = null ] && [ "$(q sd role)" = null ] && [ "$(q dd role)" = null ] && [ "$(q mm role)" = null ] && [ "$(q mm project)" = '"projects/elsewhere"' ] && [ "$(q gone role)" = null ] && [ "$(q ex role)" = null ] && ok "the rows that were left have no role and kept their fields" || bad "left rows: nl=$(q nl role) sd=$(q sd role) dd=$(q dd role) mm=$(q mm role)"
grep -q "$(printf 'tag\tba\t')" "$RLOG" && ok "one tag line per row in sessions.log" || bad "log: $(<"$RLOG")"
cp "$REG" "$HOME/reg.before"; : > "$RLOG"
out=$("$SALA" sessions tag --auto 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q ": 0 tagged" && same_file "$REG" "$HOME/reg.before" && [ ! -s "$RLOG" ] && ok "a second run changes nothing (byte-identical, no log line): idempotent" || bad "repeat: rc=$rc $out"
out=$("$SALA" sessions tag --auto ba 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q "already has role back" && ok "--auto NAME on a row that has a role: nothing changed, exit 0" || bad "named, tagged: rc=$rc $out"
out=$("$SALA" sessions tag --auto nl 2>&1); rc=$?
[ "$rc" = 3 ] && echo "$out" | grep -q "left nl" && ok "--auto NAME on a session no agents map lists: exit 3" || bad "named, not listed: rc=$rc $out"
ledger_write add late "44444444-0000-4000-8000-000000000091" late "$HOME/wa-late" >/dev/null 2>&1; addrec late false
out=$("$SALA" sessions tag --auto late 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(q late role)" = '"back"' ] && ok "--auto NAME tags that one row" || bad "named: rc=$rc $out"
ledger_write add late2 "44444444-0000-4000-8000-000000000092" late2 "$HOME/wa-late2" >/dev/null 2>&1; cp "$REG" "$HOME/reg.before"; : > "$RLOG"
for how in missing stale garbage schema; do
    case "$how" in
        missing) rm -f "$REC" ;;
        stale) mkrec "$(date -u -d '-20 minutes' +%Y-%m-%dT%H:%M:%SZ)" ;;
        garbage) echo '{"schema": 1, "generated": ' > "$REC" ;;
        schema) mkrec "$(isonow)" 2 ;;
    esac
    out=$("$SALA" sessions tag --auto 2>&1); rc=$?; dry=$("$SALA" sessions tag --auto --dry-run 2>&1); rcd=$?
    [ "$rc" = 4 ] && [ "$rcd" = 4 ] && same_file "$REG" "$HOME/reg.before" && [ ! -s "$RLOG" ] && ok "a $how project record: exit 4, nothing written, no log line" || bad "$how record: rc=$rc/$rcd $out"
done
mkrec "$(isonow)"; addrec late false
for badargs in "--auto --role back" "--auto --project projects/x" "--auto ba late" "--auto --project-key projects/x"; do
    out=$("$SALA" sessions tag $badargs 2>&1); rc=$?
    [ "$rc" != 0 ] && same_file "$REG" "$HOME/reg.before" && ok "tag $badargs: refused, nothing written" || bad "tag $badargs: rc=$rc $out"
done
out=$("$SALA" sessions tag --auto ex 2>&1); rc=$?
[ "$rc" != 0 ] && echo "$out" | grep -q "no session" && ok "a retired row is not tagged" || bad "retired: rc=$rc $out"
out=$(SALA_SESSIONS=off "$SALA" sessions tag --auto 2>&1); rc=$?
[ "$rc" != 0 ] && echo "$out" | grep -q "SALA_SESSIONS=off" && same_file "$REG" "$HOME/reg.before" && ok "SALA_SESSIONS=off: --auto refuses, nothing written" || bad "off: rc=$rc $out"

echo "== phase 5: the rule's reader counts a row with no role by the record; the watch's fill"
n=$(sessions_py back-names --record "$REC" --record-max-age 600 2>&1 | paste -sd' ')
[ "$n" = "ba late tagm" ] && ok "back-names: a stored role back (tagm, from phase 4) and a record-listed back; no front, no side session, no unlisted, no retired row" || bad "back-names: '$n'"
n=$(sessions_py front-names --record "$REC" --record-max-age 600 2>&1 | paste -sd' ')
[ "$n" = "fa gamma2 ro tage tw" ] && ok "front-names: the same reader for the front agents (a stored role front or a record-listed front; no back, no side session, no retired row)" || bad "front-names: '$n'"
cp "$REG" "$HOME/reg.before"; : > "$RLOG"
sessions_py back-names --record "$REC" --record-max-age 600 >/dev/null 2>&1; sessions_py front-names --record "$REC" --record-max-age 600 >/dev/null 2>&1
same_file "$REG" "$HOME/reg.before" && [ ! -s "$RLOG" ] && ok "back-names and front-names are read-only (file and log unchanged)" || bad "back-names or front-names wrote"
# project-sessions: the reader of the idle sleep tick, one line per live agent that has a project: <project key> TAB <name> TAB front|back
ps=$(sessions_py project-sessions --record "$REC" --record-max-age 600 2>&1); bn=" $(sessions_py back-names --record "$REC" --record-max-age 600 2>&1 | paste -sd' ') "; fn=" $(sessions_py front-names --record "$REC" --record-max-age 600 2>&1 | paste -sd' ') "
okps=1; nps=0
while IFS=$'\t' read -r pk pn pr; do
    [ -n "$pk" ] || continue; nps=$((nps + 1))
    case "$pk" in projects/*|"") okps=0 ;; esac
    case "$pr" in back) case "$bn" in *" $pn "*) ;; *) okps=0 ;; esac ;; front) case "$fn" in *" $pn "*) ;; *) okps=0 ;; esac ;; *) okps=0 ;; esac
done <<< "$ps"
[ "$okps" = 1 ] && [ "$nps" -gt 0 ] && ok "project-sessions: $nps line(s) of project key (no projects/ prefix), name and role, each role the one back-names / front-names gives that name" || bad "project-sessions: ok=$okps n=$nps — $ps"
cp "$REG" "$HOME/reg.before"; : > "$RLOG"; sessions_py project-sessions --record "$REC" --record-max-age 600 >/dev/null 2>&1
same_file "$REG" "$HOME/reg.before" && [ ! -s "$RLOG" ] && ok "project-sessions is read-only (file and log unchanged)" || bad "project-sessions wrote"
addrec late2 false; n=$(sessions_py back-names --record "$REC" --record-max-age 600 2>&1 | paste -sd' ')
[ "$n" = "ba late late2 tagm" ] && [ "$(q late2 role)" = null ] && ok "a row with no role counts by what the record says of it, before anything is written" || bad "back-names, untagged: '$n' role=$(q late2 role)"
addrec late2 true; n=$(sessions_py front-names --record "$REC" --record-max-age 600 2>&1 | paste -sd' ')
[ "$n" = "fa gamma2 late2 ro tage tw" ] && [ "$(q late2 role)" = null ] && ok "front-names: a row with no role listed as a front by the record counts, before anything is written" || bad "front-names, untagged: '$n' role=$(q late2 role)"
addrec late2 false
# the roles file (stackshot's roles.json, the Overview's Role column): a row with no role that the record places nowhere takes a front or back entry of it
ROLES="$HOME/roles.json"
mkroles() {  # <generated ISO Z> → the roles file: nl front, dd back, late2 front (the record says back), ro back (the row stores front), mm keeper, gone front but retired, sd front (a side row), ex front (a retired row)
    python3 - "$ROLES" "$1" <<'PY'
import json, sys
e = lambda role, **kw: dict({"role": role, "project": "projects/x", "live": True}, **kw)
json.dump({"generated": sys.argv[2], "ids": {}, "sessions": {
    "nl": e("front"), "dd": e("back"), "late2": e("front"), "ro": e("back"), "mm": e("keeper"), "gone": e("front", retired=True),
    "sd": e("front"), "ex": e("front"), "ghost": e("front")}}, open(sys.argv[1], "w"))
PY
}
rnames() { sessions_py "$1-names" --record "$REC" --record-max-age 600 --roles "$ROLES" --roles-max-age 1800 2>&1 | paste -sd' '; }
mkroles "$(isonow)"; cp "$REG" "$HOME/reg.before"; : > "$RLOG"
n=$(rnames front)
[ "$n" = "fa gamma2 nl ro tage tw" ] && ok "front-names with a roles file: a row with no role that the record does not place (nl) counts as front by its entry; the others are as before" || bad "front-names, roles: '$n'"
n=$(rnames back)
[ "$n" = "ba dd late late2 tagm" ] && ok "back-names with a roles file: dd (on two maps, so the record places it nowhere) counts as back by its entry" || bad "back-names, roles: '$n'"
rnames front | grep -qw ro && ! rnames back | grep -qw ro && ok "a stored role wins over the roles file (ro stays front though the file says back)" || bad "stored role: $(rnames front) / $(rnames back)"
rnames back | grep -qw late2 && ! rnames front | grep -qw late2 && ok "the record comes first: late2 (the record lists it back) is back though the roles file says front" || bad "record first: $(rnames front) / $(rnames back)"
case " $(rnames front) $(rnames back) " in *" mm "*|*" gone "*|*" sd "*|*" ex "*|*" ghost "*) bad "uncounted row counted: $(rnames front) / $(rnames back)";; *) ok "a keeper entry (mm), a retired entry (gone), a side row (sd), a retired row (ex) and a name with no live row (ghost) are not counted";; esac
same_file "$REG" "$HOME/reg.before" && [ ! -s "$RLOG" ] && ok "with a roles file back-names and front-names are still read-only (file and log unchanged)" || bad "roles read wrote"
# the keeper is a mark on one front or back agent ("keeper": true beside its role), never a role of its own: a marked entry counts with its own role, a flagged retired
# entry does not count, and an entry whose role is the old "keeper" is not counted, flagged or not (stackshot still writes that form until it removes it)
ROLES3="$HOME/roles3.json"
python3 - "$ROLES3" "$(isonow)" <<'PY'
import json, sys
e = lambda role, **kw: dict({"role": role, "project": "projects/x", "live": True}, **kw)
json.dump({"generated": sys.argv[2], "ids": {}, "sessions": {
    "mk-bld": e("back", keeper=True), "mk-main": e("front", keeper=True), "mk-ret": e("front", keeper=True, retired=True),
    "mk-oldflag": e("keeper", keeper=True), "mk-oldplain": e("keeper"), "mk-plain": e("back")}}, open(sys.argv[1], "w"))
PY
i=70
for n in mk-bld mk-main mk-ret mk-oldflag mk-oldplain mk-plain; do i=$((i + 1)); ledger_write add "$n" "44444444-0000-4000-8000-0000000000$i" "$n" "$HOME/wa-$n" >/dev/null 2>&1; sessions_set "$n" project=projects/x >/dev/null 2>&1; done
# the setup above discards its errors: an absent row would look like a row correctly refused a role, so each fixture row must exist, be live, carry projects/x and have no role of its own
for n in mk-bld mk-main mk-ret mk-oldflag mk-oldplain mk-plain; do
    [ "$(q "$n" state live)" = '"live"' ] && [ "$(q "$n" project live)" = '"projects/x"' ] && [ "$(q "$n" role live)" = null ] && ok "fixture row $n exists, is live, has project projects/x and no role" || bad "fixture row $n: state=$(q "$n" state live) project=$(q "$n" project live) role=$(q "$n" role live)"
done
kn() { sessions_py "$1-names" --record "$REC" --record-max-age 600 --roles "$ROLES3" --roles-max-age 1800 2>&1 | paste -sd' '; }
cp "$REG" "$HOME/reg.before"; : > "$RLOG"
case " $(kn back) " in *" mk-bld "*) ok "a marked builder (role back, keeper true, no separate keeper name) counts as back";; *) bad "marked builder: back=$(kn back)";; esac
case " $(kn front) " in *" mk-bld "*) bad "the marked builder also counted as front: $(kn front)";; *) ok "the marked builder is not a front agent";; esac
case " $(kn front) " in *" mk-main "*) ok "a marked non-builder (role front, keeper true) counts as front";; *) bad "marked non-builder: front=$(kn front)";; esac
case " $(kn back) " in *" mk-main "*) bad "the marked non-builder also counted as back: $(kn back)";; *) ok "the marked non-builder is not a back agent";; esac
case " $(kn front) $(kn back) " in *" mk-ret "*) bad "a flagged retired entry counted: $(kn front) / $(kn back)";; *) ok "a flagged entry that is retired (mk-ret) is not counted";; esac
case " $(kn front) $(kn back) " in *" mk-oldflag "*) bad "an old keeper role with the flag counted: $(kn front) / $(kn back)";; *) ok "an entry whose role is the old keeper is not counted even with the flag (mk-oldflag)";; esac
case " $(kn front) $(kn back) " in *" mk-oldplain "*) bad "an unflagged old keeper counted: $(kn front) / $(kn back)";; *) ok "an unflagged old keeper entry (mk-oldplain) is still not counted";; esac
case " $(kn back) " in *" mk-plain "*) ok "an entry without the flag counts as before (mk-plain: back)";; *) bad "unflagged back entry: back=$(kn back)";; esac
same_file "$REG" "$HOME/reg.before" && [ ! -s "$RLOG" ] && ok "with a marked roles file back-names and front-names are still read-only (file and log unchanged)" || bad "marked roles read wrote"
for n in mk-bld mk-main mk-ret mk-oldflag mk-oldplain mk-plain; do ledger_write retire "$n" >/dev/null 2>&1; done   # the later cases count live rows
rm -f "$ROLES3"
# the roles file matches a row by name, so a row that names another project than the entry must get nothing from it (a name reassigned to another project)
ROLES2="$HOME/roles2.json"
python3 - "$ROLES2" "$(isonow)" <<'PY'
import json, sys
e = lambda role, proj: {"role": role, "project": proj, "live": True}
json.dump({"generated": sys.argv[2], "ids": {}, "sessions": {
    "rp-same": e("front", "projects/x"), "rp-none": e("back", "projects/x"), "rp-diff": e("front", "projects/x"), "rp-bare": e("back", "x"),
    "rp-bare-diff": e("back", "y"), "rp-noproj": e("front", None)}}, open(sys.argv[1], "w"))
PY
i=60
for n in rp-same rp-none rp-diff rp-bare rp-bare-diff rp-noproj; do i=$((i + 1)); ledger_write add "$n" "44444444-0000-4000-8000-0000000000$i" "$n" "$HOME/wa-$n" >/dev/null 2>&1; done
sessions_set rp-same project=projects/x >/dev/null 2>&1; sessions_set rp-diff project=projects/y >/dev/null 2>&1
sessions_set rp-bare project=projects/x >/dev/null 2>&1; sessions_set rp-bare-diff project=projects/x >/dev/null 2>&1; sessions_set rp-noproj project=projects/x >/dev/null 2>&1
pn() { sessions_py "$1-names" --record "$REC" --record-max-age 600 --roles "$ROLES2" --roles-max-age 1800 2>&1 | paste -sd' '; }
# the setup above discards its errors: an absent row would look like a row correctly refused a role, so each fixture row must exist, be live, and carry its intended project
for pair in rp-same:projects/x rp-none:null rp-diff:projects/y rp-bare:projects/x rp-bare-diff:projects/x rp-noproj:projects/x; do   # q prints JSON: a string is quoted, none is null, an absent live row is "<none>"
    fn=${pair%%:*}; fp=${pair#*:}; [ "$fp" = null ] || fp="\"$fp\""
    [ "$(q "$fn" state live)" = '"live"' ] && [ "$(q "$fn" project live)" = "$fp" ] && ok "fixture row $fn exists, is live and has project $fp" || bad "fixture row $fn: state=$(q "$fn" state live) project=$(q "$fn" project live) (want live, $fp)"
done
n=$(pn front)
case " $n " in *" rp-same "*) ok "a row on the same project as the roles entry gets the entry's role (rp-same: front)";; *) bad "same project: '$n'";; esac
[ "$(q rp-none project)" = null ] && case " $(pn back) " in *" rp-none "*) ok "a row with no project gets the entry's role (rp-none: back)";; *) bad "row without project: $(pn back)";; esac || bad "rp-none has a project: $(q rp-none project)"
case " $(pn front) $(pn back) " in *" rp-diff "*) bad "a row on another project than the entry got its role: $(pn front) / $(pn back)";; *) ok "a row whose project differs from the entry's (projects/y against projects/x) gets no role from the file";; esac
case " $(pn back) " in *" rp-bare "*) ok "key normalization: the entry's bare slug (x) and the row's page key (projects/x) are the same project";; *) bad "bare slug vs page key: $(pn back)";; esac
case " $(pn back) " in *" rp-bare-diff "*) bad "a bare slug naming another project gave its role: $(pn back)";; *) ok "key normalization: a bare slug that names another project (y against projects/x) gives nothing";; esac
case " $(pn front) " in *" rp-noproj "*) ok "an entry with no project agrees with any row (rp-noproj: front)";; *) bad "entry without project: $(pn front)";; esac
for n in rp-same rp-none rp-diff rp-bare rp-bare-diff rp-noproj; do ledger_write retire "$n" >/dev/null 2>&1; done   # the later cases count live rows
rm -f "$ROLES2"
for how in missing stale garbage noshape; do
    case "$how" in
        missing) rm -f "$ROLES" ;;
        stale) mkroles "$(date -u -d '-2 hours' +%Y-%m-%dT%H:%M:%SZ)" ;;
        garbage) echo '{"generated": ' > "$ROLES" ;;
        noshape) printf '{"generated": "%s", "sessions": []}' "$(isonow)" > "$ROLES" ;;
    esac
    [ "$(rnames front)" = "fa gamma2 ro tage tw" ] && [ "$(rnames back)" = "ba late late2 tagm" ] && ok "a $how roles file: both lists are as without it" || bad "$how roles file: '$(rnames front)' / '$(rnames back)'"
done
n=$(sessions_py front-names --record "$REC" --record-max-age 600 2>&1 | paste -sd' ')
[ "$n" = "fa gamma2 ro tage tw" ] && ok "no --roles at all: as before" || bad "no --roles: '$n'"
rm -f "$ROLES"
rm -f "$REC"; n=$(sessions_py back-names --record "$REC" --record-max-age 600 2>&1 | paste -sd' ')
[ "$n" = "ba late tagm" ] && ok "with no record the stored roles alone count" || bad "back-names, no record: '$n'"
: > "$RLOG"; cp "$REG" "$HOME/reg.before"; sessions_fill_roles; rc=$?
[ "$rc" = 0 ] && same_file "$REG" "$HOME/reg.before" && [ ! -s "$RLOG" ] && ok "the watch's fill with no record: returns 0 and says nothing" || bad "fill, no record: rc=$rc"
mkrec "$(isonow)"; addrec late false; sessions_fill_roles; rc=$?
[ "$rc" = 0 ] && [ "$(q late2 role)" = null ] && ok "the fill leaves a row the record does not list" || bad "fill, late2: rc=$rc $(q late2 role)"
addrec late2 false; sessions_fill_roles; rc=$?
[ "$rc" = 0 ] && [ "$(q late2 role)" = '"back"' ] && [ "$(q late2 project)" = '"projects/proj-a"' ] && ok "the watch's fill (sessions_fill_roles) tags a row once the record lists it" || bad "fill: rc=$rc $(q late2 role)"
cp "$REG" "$HOME/reg.before"; SALA_SESSIONS=off sessions_fill_roles; rc=$?
[ "$rc" = 0 ] && same_file "$REG" "$HOME/reg.before" && ok "SALA_SESSIONS=off: the fill does nothing and returns 0" || bad "fill off: rc=$rc"

echo "== the surface of a front agent: sala (absent) or slack, in the row, the listings, tag and tag --auto"
# The rows here are new (sf-*): the sections above count rows by name and are left as they were.
has_field() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["sessions"]; r=[x for x in d.values() if x["name"]==sys.argv[2] and x["state"]=="live"][0]; print("yes" if sys.argv[3] in r else "no")' "$REG" "$1" "$2"; }
i=100; for n in sf-new sf-stale sf-copy sf-bad sf-back sf-man sf-none sf-unk sf-rb; do i=$((i + 1)); ledger_write add "$n" "44444444-0000-4000-8000-000000000$i" "$n" "$HOME/wa-$n" >/dev/null 2>&1; done
mkrec "$(isonow)"
python3 - "$REC" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); a = d["projects"]["prj_t1"]["agents"]
ent = lambda front, **k: dict({"front": front, "role": "x", "mandate_line": "m"}, **k)
a["sf-new"] = ent(True, surface="slack")        # a slack agent whose row has no role yet
a["sf-stale"] = ent(True)                       # lists no surface: a stale slack on its row is cleared
a["sf-copy"] = ent(True, surface="slack")       # its row has a role already and no surface
a["sf-bad"] = ent(True, surface="telegram")     # a value sala does not know
a["sf-back"] = ent(False, surface="slack")      # a back agent the record calls slack
a["sf-unk"] = ent(True, surface="telegram")     # a value sala does not know, on a row with no role yet
a["sf-rb"] = ent(True, surface="slack")         # the record says front and slack, the row says back
json.dump(d, open(sys.argv[1], "w"))
PY
"$SALA" sessions tag sf-stale --role front --project projects/proj-a >/dev/null 2>&1
"$SALA" sessions tag sf-stale --surface slack >/dev/null 2>&1
"$SALA" sessions tag sf-copy --role front --project projects/proj-a >/dev/null 2>&1
"$SALA" sessions tag sf-bad --role front --project projects/proj-a >/dev/null 2>&1
"$SALA" sessions tag sf-rb --role back --project projects/proj-a >/dev/null 2>&1
whole_row() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["sessions"]; print(json.dumps([x for x in d.values() if x["name"]==sys.argv[2] and x["state"]=="live"][0], sort_keys=True))' "$REG" "$1"; }
ROWS_BEFORE=$(for n in sf-bad sf-back sf-unk sf-rb; do whole_row "$n"; done)   # the rows --auto must leave exactly as they are
[ "$(q sf-stale surface)" = '"slack"' ] && [ "$(has_field sf-copy surface)" = no ] && ok "a manual tag --surface slack marks a front row; a row with none has no surface key" || bad "setup: $(q sf-stale surface) $(has_field sf-copy surface)"
cp "$REG" "$HOME/reg.before"; : > "$RLOG"
out=$("$SALA" sessions tag --auto --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q "would tag sf-new .*role None -> front; surface None -> slack" && echo "$out" | grep -q "would tag sf-stale .*surface slack -> None" && echo "$out" | grep -q "would tag sf-copy .*surface None -> slack" && same_file "$REG" "$HOME/reg.before" && [ ! -s "$RLOG" ] && ok "--auto --dry-run says the surface it would copy or clear (a role-less row and rows that have a role), writes nothing" || bad "dry run: rc=$rc $out"
echo "$out" | grep -qE "^sessions tag --auto: left sf-bad \([0-9a-f]{8}\): the record gives it surface 'telegram'" && ok "--auto --dry-run: a row with a role and a surface the record gives that cannot be used is reported with the reason" || bad "dry run, bad value on a roled row: $out"
out=$("$SALA" sessions tag --auto 2>&1); rc=$?
echo "$out" | grep -qE "^sessions tag --auto: left sf-bad \([0-9a-f]{8}\): the record gives it surface 'telegram'" && ok "tag --auto: a row with a role and a surface that cannot be used: one 'left NAME (ID8): reason' line" || bad "bulk, bad value on a roled row: $out"
echo "$out" | grep -qE "^sessions tag --auto: left sf-(copy|stale) " && bad "a roled row with a usable surface is reported: $out" || ok "a roled row with a usable surface stays quiet"
echo "$out" | grep -q "left sf-unk .*telegram" && ok "a role-less row whose record entry has a surface sala does not know: left, and the reason is reported" || bad "unknown surface, no reason: $out"
echo "$out" | grep -q "left sf-back .*slack agent is a front agent" && ok "a role-less back row the record calls slack: left, and the reason is reported" || bad "back+slack, no reason: $out"
echo "$out" | grep -q "left sf-rb .*role back" && ok "a row with role back that the record calls front and slack: left, and the reason is reported" || bad "role back vs record: $out"
[ "$(for n in sf-bad sf-back sf-unk sf-rb; do whole_row "$n"; done)" = "$ROWS_BEFORE" ] && ok "those rows are exactly as they were (project, role, surface and every other field), not only the surface field" || bad "rows changed: $(for n in sf-bad sf-back sf-unk sf-rb; do whole_row "$n"; done)"
[ "$(q sf-rb role)" = '"back"' ] && [ "$(has_field sf-rb surface)" = no ] && ok "auto-tagging never writes a back row that is slack (the pair a manual tag refuses)" || bad "back+slack row: $(q sf-rb role) $(q sf-rb surface)"
[ "$rc" = 0 ] && [ "$(q sf-new surface)" = '"slack"' ] && [ "$(q sf-new role)" = '"front"' ] && ok "tag --auto: a role-less row the record lists as slack takes role and surface together" || bad "new: rc=$rc $out :: $(q sf-new surface)"
[ "$(q sf-copy surface)" = '"slack"' ] && [ "$(q sf-copy role)" = '"front"' ] && ok "tag --auto copies the record's surface onto a row that already has a role" || bad "copy: $(q sf-copy surface) $out"
[ "$(has_field sf-stale surface)" = no ] && ok "a record without the field clears a stale slack (the key is gone, not set to sala)" || bad "stale: $(q sf-stale surface)"
[ "$(has_field sf-bad surface)" = no ] && [ "$(has_field sf-none surface)" = no ] && ok "a value sala does not know is not copied; a row the record does not list keeps what it has" || bad "bad/none: $(q sf-bad surface)"
out=$("$SALA" sessions tag --auto sf-back 2>&1); rc=$?
[ "$(has_field sf-back surface)" = no ] && [ "$(q sf-back role)" = null ] && [ "$rc" = 0 ] && echo "$out" | grep -q "slack agent is a front agent" && ok "a back agent the record calls slack is left whole, named: exit 0 (it is on a map), the reason said" || bad "back: rc=$rc $out $(q sf-back surface)"
out=$("$SALA" sessions tag --auto sf-bad 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -qE "^sessions tag --auto: left sf-bad \([0-9a-f]{8}\): the record gives it surface 'telegram'" && [ "$(whole_row sf-bad)" = "$(sed -n 1p <<< "$ROWS_BEFORE")" ] && ok "tag --auto NAME on a row with a role and a surface that cannot be used: the reason said, exit 0, the row unchanged" || bad "named bad on a roled row: rc=$rc $out"
out=$("$SALA" sessions tag --auto sf-unk 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q "left sf-unk" && [ "$(q sf-unk role)" = null ] && [ "$(q sf-unk project)" = null ] && ok "tag --auto NAME on a row with an unusable surface: exit 0 (never 3, which marks a throwaway), the row untouched" || bad "named unk: rc=$rc $out"
out=$("$SALA" sessions tag --auto sf-rb 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q "left sf-rb .*role back" && [ "$(has_field sf-rb surface)" = no ] && ok "tag --auto NAME on a back row the record calls slack: left, the reason said" || bad "named rb: rc=$rc $out"
"$SALA" sessions tag sf-none --role front >/dev/null 2>&1; "$SALA" sessions tag sf-none --surface slack >/dev/null 2>&1
out=$("$SALA" sessions tag --auto 2>&1); rc=$?
echo "$out" | grep -q "left sf-none " && bad "a row with a role that the record does not place is reported: $out" || ok "a row with a role that the record does not place stays quiet"
[ "$(q sf-none surface)" = '"slack"' ] && ok "a row the record places nowhere keeps its surface" || bad "unlisted keeps: $(q sf-none surface)"
cp "$REG" "$HOME/reg.before"; : > "$RLOG"
out=$("$SALA" sessions tag --auto 2>&1); rc=$?
[ "$rc" = 0 ] && same_file "$REG" "$HOME/reg.before" && [ ! -s "$RLOG" ] && ok "tag --auto again: byte-identical, no log line (idempotent with a surface in play)" || bad "repeat: rc=$rc $out"
out=$("$SALA" sessions tag --auto sf-copy 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q "already has role front: nothing changed" && ok "--auto NAME on a row with a role and nothing to change says so" || bad "named: rc=$rc $out"
out=$("$SALA" sessions tag --auto --surface slack 2>&1); rc=$?
[ "$rc" != 0 ] && same_file "$REG" "$HOME/reg.before" && ok "tag --auto --surface is refused: the record gives it" || bad "auto --surface: rc=$rc $out"

echo "== the surface: an explicit EMPTY surface in the record (\"\" or null) is refused, an absent field still means sala"
# A present-but-empty `surface` on an agent entry is no value: the contract defaults only an ABSENT field, so an empty one must not clear a Slack tag.
i=120; for n in sf-empty sf-null; do i=$((i + 1)); ledger_write add "$n" "44444444-0000-4000-8000-000000000$i" "$n" "$HOME/wa-$n" >/dev/null 2>&1; done
python3 - "$REC" <<'PY2'
import json, sys
d = json.load(open(sys.argv[1])); a = d["projects"]["prj_t1"]["agents"]
a["sf-empty"] = {"front": True, "role": "x", "mandate_line": "m", "surface": ""}      # present, empty string
a["sf-null"] = {"front": True, "role": "x", "mandate_line": "m", "surface": None}     # present, JSON null
json.dump(d, open(sys.argv[1], "w"))
PY2
"$SALA" sessions tag sf-empty --role front --project projects/proj-a >/dev/null 2>&1
"$SALA" sessions tag sf-empty --surface slack >/dev/null 2>&1                          # a Slack tag an empty entry must not clear
EMPTY_BEFORE=$(for n in sf-empty sf-null; do whole_row "$n"; done)
[ "$(q sf-empty surface)" = '"slack"' ] && ok "setup: sf-empty is a front row tagged slack; sf-null has no role" || bad "setup empty: $(q sf-empty surface)"
cp "$REG" "$HOME/reg.before"; : > "$RLOG"
out=$("$SALA" sessions tag --auto --dry-run 2>&1); rc=$?
echo "$out" | grep -qE "^sessions tag --auto: left sf-empty \([0-9a-f]{8}\): the record gives it an empty surface: a surface is sala or slack" && ! echo "$out" | grep -q "would tag sf-empty" && same_file "$REG" "$HOME/reg.before" && ok "--auto --dry-run: an empty surface on a row with a role is reported with the reason, and not as a clear of its slack" || bad "dry run, empty: rc=$rc $out"
echo "$out" | grep -qE "^sessions tag --auto: left sf-null \([0-9a-f]{8}\): the record gives it an empty surface" && ok "--auto --dry-run: a JSON null surface is reported the same way" || bad "dry run, null: $out"
out=$("$SALA" sessions tag --auto 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q "left sf-empty " && echo "$out" | grep -q "left sf-null " && [ "$(for n in sf-empty sf-null; do whole_row "$n"; done)" = "$EMPTY_BEFORE" ] && [ "$(q sf-empty surface)" = '"slack"' ] && ok "tag --auto: rows with an empty or null surface are left whole (the Slack tag stays, the role-less row gets no project or role)" || bad "bulk empty: rc=$rc $out"
out=$("$SALA" sessions tag --auto sf-empty 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q "left sf-empty .*empty surface" && [ "$(whole_row sf-empty)" = "$(sed -n 1p <<< "$EMPTY_BEFORE")" ] && ok "tag --auto NAME on a row with a role and an empty surface: the reason said, exit 0, the row unchanged" || bad "named empty: rc=$rc $out"
out=$("$SALA" sessions tag --auto sf-null 2>&1); rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q "left sf-null .*empty surface" && [ "$(whole_row sf-null)" = "$(sed -n 2p <<< "$EMPTY_BEFORE")" ] && ok "tag --auto NAME on a role-less row with a null surface: exit 0, the row untouched" || bad "named null: rc=$rc $out"
"$SALA" sessions tag sf-empty --surface sala >/dev/null 2>&1                            # put the row back: the listings below count the slack rows
[ "$(has_field sf-empty surface)" = no ] && ok "teardown: sf-empty is a sala row again" || bad "teardown: $(q sf-empty surface)"

echo "== record-surface: reads only the project record (a registry that is missing, corrupt or unreadable changes nothing), exit 3 / 4 / 5"
rsf() { sessions_py record-surface "$1" ${2:+--project "$2"} --record "${RSF_REC:-$REC}" --record-max-age 600 2>&1; }
out=$(rsf sf-new); rc=$?;      [ "$rc" = 0 ] && [ "$out" = slack ] && ok "record-surface: a slack entry answers slack" || bad "rsf slack: rc=$rc $out"
out=$(rsf sf-stale); rc=$?;    [ "$rc" = 0 ] && [ "$out" = sala ] && ok "record-surface: an entry with no surface field answers sala" || bad "rsf absent: rc=$rc $out"
out=$(rsf fa projects/proj-a); rc=$?; [ "$rc" = 0 ] && [ "$out" = sala ] && ok "record-surface NAME --project P reads P's map" || bad "rsf project: rc=$rc $out"
out=$(rsf sf-empty); rc=$?;    [ "$rc" = 5 ] && echo "$out" | grep -q "empty surface: a surface is sala or slack" && ok "record-surface: an empty surface is exit 5 with the reason" || bad "rsf empty: rc=$rc $out"
out=$(rsf sf-null); rc=$?;     [ "$rc" = 5 ] && echo "$out" | grep -q "empty surface" && ok "record-surface: a JSON null surface is exit 5 as well" || bad "rsf null: rc=$rc $out"
out=$(rsf sf-bad); rc=$?;      [ "$rc" = 5 ] && echo "$out" | grep -q "surface 'telegram'" && ok "record-surface: a surface sala does not know is exit 5" || bad "rsf telegram: rc=$rc $out"
out=$(rsf sf-back); rc=$?;     [ "$rc" = 5 ] && echo "$out" | grep -q "slack agent is a front agent" && ok "record-surface: a back agent called slack is exit 5" || bad "rsf back slack: rc=$rc $out"
out=$(rsf no-such-agent); rc=$?; [ "$rc" = 3 ] && ok "record-surface: a name on no map is exit 3" || bad "rsf unlisted: rc=$rc $out"
out=$(rsf dd); rc=$?;          [ "$rc" = 3 ] && ok "record-surface: a name on the maps of two projects is exit 3" || bad "rsf two maps: rc=$rc $out"
out=$(rsf sf-new projects/proj-b); rc=$?; [ "$rc" = 3 ] && ok "record-surface: a name not on P's map is exit 3" || bad "rsf other project: rc=$rc $out"
out=$(RSF_REC="$HOME/no-such-record.json" rsf sf-new); rc=$?; [ "$rc" = 4 ] && ok "record-surface: a missing record is exit 4" || bad "rsf no record: rc=$rc $out"
cp "$REC" "$REC.keep"; python3 -c 'import json,sys; f=sys.argv[1]; d=json.load(open(f)); d["generated"]="2020-01-01T00:00:00Z"; json.dump(d, open(f,"w"))' "$REC"
out=$(rsf fa); rc=$?; [ "$rc" = 4 ] && ok "record-surface: a stale record is exit 4" || bad "rsf stale: rc=$rc $out"
mv "$REC.keep" "$REC"
cp "$REG" "$HOME/reg.good2"
reg_cases() {  # <label>: the answers are the same whatever state the registry file is in
    local label=$1 out rc
    out=$(rsf sf-new); rc=$?;   [ "$rc" = 0 ] && [ "$out" = slack ] && ok "record-surface, registry $label: slack still answers slack" || bad "rsf $label slack: rc=$rc $out"
    out=$(rsf fa); rc=$?;       [ "$rc" = 0 ] && [ "$out" = sala ] && ok "record-surface, registry $label: sala still answers sala" || bad "rsf $label sala: rc=$rc $out"
    out=$(rsf sf-empty); rc=$?; [ "$rc" = 5 ] && ok "record-surface, registry $label: an empty surface is still exit 5" || bad "rsf $label empty: rc=$rc $out"
    out=$(rsf no-such-agent); rc=$?; [ "$rc" = 3 ] && ok "record-surface, registry $label: an unlisted name is still exit 3" || bad "rsf $label unlisted: rc=$rc $out"
    out=$(RSF_REC="$HOME/no-such-record.json" rsf fa); rc=$?; [ "$rc" = 4 ] && ok "record-surface, registry $label: a missing record is still exit 4" || bad "rsf $label no record: rc=$rc $out"
}
echo '{this is not json' > "$REG";           reg_cases corrupt
echo '{"schema": 1}' > "$REG";                reg_cases "without a sessions object"
rm -f "$REG";                                 reg_cases missing
if [ "$(id -u)" != 0 ]; then
    cp "$HOME/reg.good2" "$REG"; chmod 000 "$REG"; reg_cases unreadable
    chmod 600 "$REG"   # only the branch that set mode 000 resets it: as root the registry is still absent here and a chmod on it would fail
else   # chmod 000 blocks no read by root, so the case would pass without testing anything; the never-opened check below does not depend on it
    echo "  skip record-surface, registry unreadable: running as root, where chmod 000 blocks no read"
fi
cp "$HOME/reg.good2" "$REG"; chmod 600 "$REG"   # restore: copy first (the file may be absent), then the mode, so root and non-root end the same
same_file "$REG" "$HOME/reg.good2" && ok "the registry is back as it was" || bad "registry not restored"
out=$(sessions_py slack-names 2>&1); rc=$?
[ "$rc" = 0 ] && ok "slack-names reads the registry again" || bad "slack-names after restore: rc=$rc $out"

echo "== record-surface never opens the registry (the cases above see only what it answers: a change that loaded the registry and swallowed the failure would still pass them)"
# nolookup.py <sessions.py> <registry> <sentinel> <args...>: runs sessions.py's main() in this process with the registry stubbed. Registry.load, and any
# open / exists / getsize of the registry file itself, write the sentinel and raise; the exit status and what main() printed come back on stdout.
cat > "$HOME/nolookup.py" <<'PY'
import builtins, contextlib, importlib.util, io, os, pathlib, sys
src, reg, sentinel = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("sessions_under_test", src)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
def hit(what):
    with open(sentinel, "a") as f:
        f.write("the registry was touched: %s\n" % what)
    raise AssertionError("record-surface touched the registry: %s" % what)
def stub_load(self):
    hit("Registry.load() was called")
m.Registry.load = stub_load
real_open, real_exists, real_getsize = builtins.open, os.path.exists, os.path.getsize
real_io_open, real_path_open = io.open, pathlib.Path.open
real_read_text, real_read_bytes = pathlib.Path.read_text, pathlib.Path.read_bytes
def is_reg(p): return isinstance(p, (str, bytes, os.PathLike)) and os.fsdecode(p) == reg
def guarded_open(p, *a, **k):
    if is_reg(p): hit("open(%s)" % reg)
    return real_open(p, *a, **k)
def guarded_io_open(p, *a, **k):   # io.open is a second name for the builtin: patching builtins.open leaves it, and what pathlib reads through, untouched
    if is_reg(p): hit("io.open(%s)" % reg)
    return real_io_open(p, *a, **k)
def guarded_path_open(self, *a, **k):
    if is_reg(self): hit("Path.open(%s)" % reg)
    return real_path_open(self, *a, **k)
def guarded_read_text(self, *a, **k):
    if is_reg(self): hit("Path.read_text(%s)" % reg)
    return real_read_text(self, *a, **k)
def guarded_read_bytes(self, *a, **k):
    if is_reg(self): hit("Path.read_bytes(%s)" % reg)
    return real_read_bytes(self, *a, **k)
def guarded_exists(p):
    if is_reg(p): hit("os.path.exists(%s)" % reg)
    return real_exists(p)
def guarded_getsize(p):
    if is_reg(p): hit("os.path.getsize(%s)" % reg)
    return real_getsize(p)
builtins.open, os.path.exists, os.path.getsize = guarded_open, guarded_exists, guarded_getsize
io.open, pathlib.Path.open, pathlib.Path.read_text, pathlib.Path.read_bytes = guarded_io_open, guarded_path_open, guarded_read_text, guarded_read_bytes
if sys.argv[4:5] == ["--selftest"]:   # the guard itself: every way of reading the registry must trip it (a guard that trips on nothing proves nothing)
    for label, call in (("Registry.load", lambda: m.Registry.load(None)), ("open", lambda: open(reg)), ("io.open", lambda: io.open(reg)),
                        ("Path.open", lambda: pathlib.Path(reg).open()), ("Path.read_text", lambda: pathlib.Path(reg).read_text()),
                        ("Path.read_bytes", lambda: pathlib.Path(reg).read_bytes()), ("os.path.exists", lambda: os.path.exists(reg)),
                        ("os.path.getsize", lambda: os.path.getsize(reg))):
        try: call(); print("%s: NOT guarded" % label)
        except AssertionError: print("%s: guarded" % label)
    sys.exit(0)
sys.argv = ["sessions.py", "--file", reg] + sys.argv[4:]
out, err = io.StringIO(), io.StringIO()
with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
    rc = m.main()
print("rc=%s" % rc); print(out.getvalue().strip()); print(err.getvalue().strip())
PY
SENT="$HOME/registry-touched"
out=$(python3 -I "$HOME/nolookup.py" "$SALA_SESSIONS_PY" "$REG" "$SENT" --selftest 2>&1)
rm -f "$SENT"
want=$(printf '%s: guarded\n' Registry.load open io.open Path.open Path.read_text Path.read_bytes os.path.exists os.path.getsize)
[ "$out" = "$want" ] && ok "the guard trips on Registry.load, open, io.open, Path.open, Path.read_text, Path.read_bytes, os.path.exists and os.path.getsize" || bad "the guard misses a way of reading the registry: $out"
nolookup_ok() {  # <label> <name> <expected rc> <expected stdout, "" = any> [<expected stderr fragment>]: the arguments are the ones rsf passes, the record is $NL_REC (default $REC)
    local out
    rm -f "$SENT"
    out=$(python3 -I "$HOME/nolookup.py" "$SALA_SESSIONS_PY" "$REG" "$SENT" record-surface "$2" --record "${NL_REC:-$REC}" --record-max-age 600 2>&1)
    if [ -e "$SENT" ]; then bad "record-surface ($1) touched the registry: $(tr '\n' ' ' < "$SENT")"
    elif [ "$(sed -n 1p <<< "$out")" = "rc=$3" ] && { [ -z "$4" ] || [ "$(sed -n 2p <<< "$out")" = "$4" ]; } && { [ -z "${5:-}" ] || sed -n '2,$p' <<< "$out" | grep -qF -- "$5"; }; then ok "record-surface ($1): the registry is never opened and the answer is right (rc=$3${4:+, $4})"
    else bad "record-surface ($1): wrong answer with the registry stubbed: $out"; fi
}
nolookup_ok "a slack name" sf-new 0 slack
nolookup_ok "a sala name" fa 0 sala
nolookup_ok "an empty-surface name" sf-empty 5 ""
# a registry fallback used only when the record cannot answer would keep the answers above and break here: with no record at all the answer is exit 4, nothing on stdout, never a registry lookup
NL_REC="$HOME/no-such-record.json" nolookup_ok "no project record at all, a name the registry has" sf-new 4 "" "no project record at"
NL_REC="$HOME/no-such-record.json" nolookup_ok "no project record at all, a name the registry lacks" no-such-agent 4 "" "no project record at"
rm -f "$SENT"

echo "== the surface: a manual tag, its refusals, and the value read back"
out=$("$SALA" sessions tag sf-man --role front --surface slack 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(q sf-man surface)" = '"slack"' ] && [ "$(q sf-man role)" = '"front"' ] && ok "tag --role front --surface slack sets both" || bad "tag: rc=$rc $out"
cp "$REG" "$HOME/reg.before"
for v in telegram Slack ""; do
    out=$("$SALA" sessions tag sf-man --surface "$v" 2>&1); rc=$?
    [ "$rc" != 0 ] && same_file "$REG" "$HOME/reg.before" && echo "$out" | grep -qi "surface" && ok "tag --surface '$v' is refused and says so, nothing written" || bad "tag --surface '$v': rc=$rc $out"
done
out=$("$SALA" sessions tag sf-man --role back 2>&1); rc=$?
[ "$rc" != 0 ] && echo "$out" | grep -qi "slack" && same_file "$REG" "$HOME/reg.before" && ok "--role back on a slack row is refused (a slack agent is a front agent), nothing written" || bad "slack to back: rc=$rc $out"
out=$("$SALA" sessions tag sf-man --role back --surface sala 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(q sf-man role)" = '"back"' ] && [ "$(has_field sf-man surface)" = no ] && ok "--role back --surface sala is one move: the role changes and the surface key goes" || bad "to back: rc=$rc $out"
out=$("$SALA" sessions tag sf-none --surface sala 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(has_field sf-none surface)" = no ] && ok "--surface sala takes the mark off: the row is stored without the field" || bad "sala: rc=$rc $out"
out=$("$SALA" sessions tag sf-back --surface slack 2>&1); rc=$?
[ "$rc" != 0 ] && echo "$out" | grep -qi "front" && [ "$(has_field sf-back surface)" = no ] && ok "--surface slack on a back row is refused" || bad "slack on back: rc=$rc $out"
ledger_write add sf-roleless "44444444-0000-4000-8000-000000000199" sf-roleless "$HOME/wa-sf-roleless" >/dev/null 2>&1
out=$("$SALA" sessions tag sf-roleless --surface slack 2>&1); rc=$?
[ "$rc" != 0 ] && [ "$(has_field sf-roleless surface)" = no ] && ok "--surface slack on a row with no role is refused (it needs the front role, given or on the row)" || bad "slack, no role: rc=$rc $out"
out=$("$SALA" sessions tag sf-roleless --role front --surface sala 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(has_field sf-roleless surface)" = no ] && ok "--surface sala on a row that never had one changes nothing but the role" || bad "sala on none: rc=$rc $out"

echo "== the surface: set, a bad value on disk, the listings"
sessions_set sf-roleless role=front surface=slack >/dev/null 2>&1; rc=$?
[ "$(q sf-roleless surface)" = '"slack"' ] && ok "set surface=slack (what spawn writes) stores the key" || bad "set: rc=$rc $(q sf-roleless surface)"
sessions_set sf-roleless surface=sala >/dev/null 2>&1
[ "$(has_field sf-roleless surface)" = no ] && ok "set surface=sala removes the key" || bad "set sala: $(q sf-roleless surface)"
cp "$REG" "$HOME/reg.good"
sessions_set sf-roleless role=back surface=slack >/dev/null 2>&1
[ "$(has_field sf-roleless surface)" = no ] && [ "$(q sf-roleless role)" = '"front"' ] && ok "set refuses a slack row with the back role, nothing written" || bad "set slack back: $(q sf-roleless surface) $(q sf-roleless role)"
sessions_set sf-roleless surface=telegram >/dev/null 2>&1
[ "$(has_field sf-roleless surface)" = no ] && ok "set surface=telegram is refused, nothing written" || bad "set bad: $(q sf-roleless surface)"
sessions_set sf-roleless surface=slack >/dev/null 2>&1
out=$("$SALA" sessions 2>&1)
echo "$out" | grep -E "^[0-9a-f]{8} +sf-copy " | grep -q "front \[slack\]" && echo "$out" | grep -E "^[0-9a-f]{8} +sf-roleless " | grep -q "front \[slack\]" && ok "sessions: a slack row's ROLE reads 'front [slack]'" || bad "list: $out"
echo "$out" | grep -E "^[0-9a-f]{8} +ba " | grep -q "slack" && bad "a sala row carries the mark: $out" || ok "sessions: a sala row has no mark"
"$SALA" sessions --json > "$HOME/list.json" 2>&1
python3 - "$HOME/list.json" <<'PY' && ok "sessions --json: surface is slack on a slack row and the key is absent on every other" || bad "list --json: $(head -c 300 "$HOME/list.json")"
import json, sys
rows = json.load(open(sys.argv[1]))["sessions"]
slack = sorted(r["name"] for r in rows if r.get("surface") == "slack")
assert slack == ["sf-copy", "sf-new", "sf-roleless"], slack
assert all("surface" not in r for r in rows if r["name"] not in slack)
assert all(r.get("surface") in (None, "slack") for r in rows)
PY
out=$("$SALA" sessions resolve sf-copy 2>&1); rc=$?
echo "$out" | grep -q "^role: .*front \[slack\]" && ok "resolve prints the mark after the role" || bad "resolve: rc=$rc $out"
out=$("$SALA" sessions resolve sf-copy --json 2>&1)
echo "$out" | grep -q '"surface": "slack"' && ok "resolve --json carries surface for a slack row" || bad "resolve json: $out"
out=$("$SALA" sessions resolve ba --json 2>&1)
echo "$out" | grep -q '"surface"' && bad "resolve --json carries surface for a sala row: $out" || ok "resolve --json has no surface for a sala row"
n=$(sessions_py slack-names 2>&1 | paste -sd' ')
[ "$n" = "sf-copy sf-new sf-roleless" ] && ok "slack-names: the live slack rows by name, one per word" || bad "slack-names: '$n'"
cp "$REG" "$HOME/reg.before"; : > "$RLOG"; sessions_py slack-names >/dev/null 2>&1
same_file "$REG" "$HOME/reg.before" && [ ! -s "$RLOG" ] && ok "slack-names is read-only" || bad "slack-names wrote"
python3 - "$ROOT" "$REG" <<'PY' && ok "the published copy carries surface only on a slack row" || bad "export_doc surface"
import sys
sys.path.insert(0, sys.argv[1] + "/lib")
import sessions as S
d = S.export_doc(sys.argv[2], "a", "2026-01-01T00:00:00Z")["sessions"]
by = {x["name"]: x for x in d.values()}
assert by["sf-copy"]["surface"] == "slack" and by["sf-new"]["surface"] == "slack"
assert "surface" not in by["ba"] and "surface" not in by["sf-man"]
PY

echo "== the surface: a value sala does not know, on disk, is refused wherever it is read"
cp "$REG" "$HOME/reg.good"
python3 - "$REG" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
r = [x for x in d["sessions"].values() if x["name"] == "sf-copy"][0]
r["surface"] = "telegram"
json.dump(d, open(sys.argv[1], "w"))
PY
cp "$REG" "$HOME/reg.bad"
out=$("$SALA" sessions 2>&1); rc=$?
[ "$rc" != 0 ] && echo "$out" | grep -q "surface" && echo "$out" | grep -q "sf-copy" && ok "a row with surface 'telegram': sessions refuses and names the row" || bad "bad row, list: rc=$rc $out"
out=$("$SALA" sessions tag sf-man --role front 2>&1); rc=$?
[ "$rc" != 0 ] && same_file "$REG" "$HOME/reg.bad" && ok "a write meets the same refusal and leaves the file as it was" || bad "bad row, tag: rc=$rc $out"
python3 - "$ROOT" "$REG" <<'PY' && ok "the publish refuses it too" || bad "export_doc on a bad surface"
import sys
sys.path.insert(0, sys.argv[1] + "/lib")
import sessions as S
try:
    S.export_doc(sys.argv[2], "a", "2026-01-01T00:00:00Z")
except S.RegistryError as e:
    assert "surface" in str(e)
else:
    raise SystemExit("no refusal")
PY
cp "$HOME/reg.good" "$REG"
out=$("$SALA" sessions 2>&1); rc=$?
[ "$rc" = 0 ] && ok "the registry reads again once the value is back" || bad "after restore: rc=$rc $out"

[ "$fail" = 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
