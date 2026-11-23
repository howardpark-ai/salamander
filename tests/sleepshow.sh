#!/usr/bin/env bash
# Sleeping sessions, stage 3 (DISPLAY): a sleeping session shows as sleeping everywhere sala lists sessions, never as a dead one, and stackshot's contract names
# what it may read. Stage 1 (tests/sleeping.sh) made the marker `$SALA_SLEEP_DIR/<conversation uuid>` (one line, `<ISO-Z time> <name>`); stage 2
# (tests/sleepverbs.sh) made `sala sleep` and `sala wake`. Nothing here puts a session to sleep: a marker is written by hand next to a hand-made registry, pane
# map and live registry file. What is checked:
#  - `sala sessions` (text): the sleeper's STATE column says `sleeping` and a line under the table says since when, in SALA_TZ (KST here), with the wake that
#    resumes it; the control's STATE stays `live` and has no such line; a retired row and a marker for another conversation add nothing;
#  - `sala sessions --json`: the sleeper's row carries `sleeping` (the marker's ISO-Z time) with `state` still `live`; the control's row has no such key and its
#    keys are exactly the registry's; with no marker directory no row carries the key and the output is the registry's, byte for byte as the same call before;
#  - the heartbeat: `sessions.json` (interface 1) gets a row for the sleeper keyed by its conversation uuid (name, url, seen, machine, `sleeping`), the control's row
#    has no `sleeping`, a stale marker (its uuid is on no pane-map row) and a marker whose conversation a live row already has make no second row; a second run
#    changes no byte (the row keeps its `seen`); `session-registry.json` (interface 19) has `sleeping` on the sleeper's row, `state` still `live`, and on no other
#    row; after a wake (marker removed) the sleeper's `sessions.json` row is gone and the registry row loses the key;
#  - the contract text (docs/stackshot-contracts.md): `contract-version: 53`, its changelog lines (51 to 53), the index row and the section "35. Sleeping sessions" name the
#    marker directory and line, the `sleeping` field in `sessions.json` and `sala sessions --json`, and the wake `sala op wake --only NAME`; no 54th version;
#  - the teaching text: docs/subcommands.md and the heartbeat's header say the same, and `sala help` shows the `sleeping` state of `sessions`.
# SAFETY: HOME is a mktemp -d held with flock and removed on exit; no tmux server, no claude, no network; the heartbeat runs `--no-push` with no fleet hosts.
# Usage: bash tests/sleepshow.sh   (exit 0 = pass)
set -u
unset TMUX TMUX_PANE XDG_STATE_HOME SALA_MASTER SALA_SLEEP_DIR SALA_FLEET_HOSTS SALA_SESSIONS_FILE SALA_SIDECAR SALA_STATE_DIR SALA_SESSION_URL
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
SANDBOX=""
cleanup() { [ -z "$SANDBOX" ] || { exec 8<&-; rm -rf "$SANDBOX" 2>/dev/null; }; true; }; trap cleanup EXIT   # set before the temp folder exists
SANDBOX=$(mktemp -d); export HOME=$SANDBOX SALA_CONFIG=/dev/null SALA_TZ=Asia/Seoul
case "$HOME" in /tmp/*|"${TMPDIR:-/tmp}"/*) ;; *) echo "sleepshow: HOME is not a temporary directory ($HOME) - refusing to run"; exit 1;; esac
exec 8< "$SANDBOX"; flock -n 8 2>/dev/null   # systemd-tmpfiles' ageing skips a directory held with flock
mkdir -p "$HOME/.claude/sessions" "$HOME/.claude/projects" "$HOME/.local/share/tmux/resurrect"
export SALA_AUTO_UPDATE=off SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" PYTHONDONTWRITEBYTECODE=1
SALA="$ROOT/bin/salamander"
. "$ROOT/lib/common.sh"
MAP="$SALA_SIDECAR"; REG="$SALA_SESSIONS_FILE"; SLP="$SALA_SLEEP_DIR"
[ "$SLP" = "$SALA_STATE_DIR/sleeping" ] || { echo "sleepshow: SALA_SLEEP_DIR is not in the sandbox ($SLP)"; exit 1; }
UA=aaaaaaaa-0000-4000-8000-000000000001   # alpha: asleep
UB=bbbbbbbb-0000-4000-8000-000000000002   # beta: the control, live, never asleep
UC=cccccccc-0000-4000-8000-000000000003   # gamma: a marker with no pane-map row (stale)
UD=dddddddd-0000-4000-8000-000000000004   # delta: a registry row retired, its marker left behind
UE=eeeeeeee-0000-4000-8000-000000000005   # epsilon: a marker, a pane-map row and a live claude on the same conversation (a wake in flight); no registry row
SINCE=2026-11-22T06:10:00Z                # 15:10 KST, Sunday
mkdir -p "$SLP"
python3 - "$REG" "$UA" "$UB" "$UD" <<'PY'
import json, sys
reg, ua, ub, ud = sys.argv[1:5]
def row(i, name, tr, state="live", created="2026-11-20T00:00:00Z"):
    return {"id": i, "name": name, "project": None, "role": None, "lane": "subscription-1", "model": "opus", "effort": "high", "pane": name, "cwd": "/w/" + name,
            "machine": "q", "created": created, "state": state, "retired_at": "2026-11-21T01:00:00Z" if state == "retired" else None, "aliases": [],
            "transcripts": [{"id": t, "machine": "q", "at": created, "why": "add"} for t in tr]}
rows = [row("11111111-aaaa-4000-8000-000000000001", "alpha", [ua], created="2026-11-20T00:00:01Z"),
        row("22222222-aaaa-4000-8000-000000000002", "beta", [ub], created="2026-11-20T00:00:02Z"),
        row("44444444-aaaa-4000-8000-000000000004", "delta", [ud], "retired", "2026-11-20T00:00:04Z")]
json.dump({"schema": 1, "written": "2026-11-21T00:00:00Z", "sessions": {r["id"]: r for r in rows}}, open(reg, "w"), indent=2)
PY
printf '%s\t%s\t%s\t%s\n' alpha "$UA" alpha /w/alpha beta "$UB" beta /w/beta epsilon "$UE" epsilon /w/epsilon > "$MAP"   # gamma and delta have no pane-map row
for u in "$UA:alpha" "$UC:gamma" "$UD:delta" "$UE:epsilon"; do printf '%s %s\n' "$SINCE" "${u#*:}" > "$SLP/${u%%:*}"; done
# the control's live registry file (the heartbeat's source): this script's own pid is a live pid; a second live row holds epsilon's conversation (a wake in flight)
cat > "$HOME/.claude/sessions/$$.json" <<EOF
{"pid": $$, "sessionId": "$UB", "name": "beta", "cwd": "/w/beta", "status": "idle", "tmux": "beta:@1.%1", "bridgeSessionId": "session_beta"}
EOF
cat > "$HOME/.claude/sessions/$PPID.json" <<EOF
{"pid": $PPID, "sessionId": "$UE", "name": "epsilon", "cwd": "/w/epsilon", "status": "idle", "tmux": "epsilon:@2.%2"}
EOF
JQ() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(eval(sys.argv[1]), sort_keys=True))' "$1"; }   # JQ <python expr over d> < json

echo "== sala sessions (text): the sleeper's state says sleeping, with since when; the control stays live"
OUT=$("$SALA" sessions 2>&1); RC=$?
a_line=$(grep -E '^[^ ]+ +alpha ' <<< "$OUT"); b_line=$(grep -E '^[^ ]+ +beta ' <<< "$OUT")
[ "$RC" = 0 ] && has "$a_line" sleeping && ! has "$a_line" " live " && ok "alpha: STATE is 'sleeping'" || bad "alpha line: rc=$RC '$a_line'"
has "$b_line" live && ! has "$b_line" sleeping && ok "beta (control): STATE stays 'live'" || bad "beta line: '$b_line'"
has "$OUT" "sleeping: alpha since Sun Nov 22nd 15:10 KST" && has "$OUT" "sala wake alpha" && ok "the line under the table: since Sun Nov 22nd 15:10 KST (the page's zone, never UTC), and the wake" || bad "since line: $OUT"
[ "$(grep -c '^sleeping: ' <<< "$OUT")" = 1 ] && ok "one such line, for alpha: none for beta, the retired delta or the marker with no row" || bad "lines: $(grep '^sleeping: ' <<< "$OUT")"
has "$OUT" "sleeping: gamma" && bad "a stale marker (no registry row) was listed" || ok "a marker for a conversation with no registry row adds nothing"
OUT=$("$SALA" sessions --all 2>&1); d_line=$(grep -E '^[^ ]+ +delta ' <<< "$OUT")
has "$d_line" retired && ! has "$d_line" sleeping && ok "a retired row stays 'retired' whatever marker is left" || bad "delta: '$d_line'"

echo "== sala sessions --json: the key on the sleeper only, state still live"
"$SALA" sessions --json > "$HOME/list.json" 2>"$HOME/list.err"; RC=$?
[ "$RC" = 0 ] && ok "sessions --json runs" || bad "json rc=$RC: $(cat "$HOME/list.err")"
r=$(JQ '{r["name"]: [r["state"], r.get("sleeping")] for r in d["sessions"]}' < "$HOME/list.json")
[ "$r" = '{"alpha": ["live", "2026-11-22T06:10:00Z"], "beta": ["live", null]}' ] && ok "alpha: sleeping = the marker's time, state live; beta: no key" || bad "rows: $r"
r=$(JQ '[sorted(r) for r in d["sessions"] if r["name"] == "beta"][0] == sorted(["id","name","aliases","project","role","lane","model","effort","pane","cwd","machine","created","state","retired_at","transcripts"])' < "$HOME/list.json")
[ "$r" = true ] && ok "beta's keys are the registry's, nothing added" || bad "beta keys: $(JQ '[sorted(r) for r in d["sessions"] if r["name"] == "beta"][0]' < "$HOME/list.json")"
mv "$SLP" "$SLP.off"
"$SALA" sessions --json > "$HOME/list-off.json" 2>/dev/null; mv "$SLP.off" "$SLP"
! grep -q sleeping "$HOME/list-off.json" && ok "with no marker directory no row carries the key" || bad "key without markers"
r=$(JQ '[k for k in set(x for r in d["sessions"] for x in r) if k == "sleeping"]' < "$HOME/list-off.json"); [ "$r" = "[]" ] && ok "(read back as JSON: no row has it)" || bad "keys: $r"

echo "== the heartbeat: sessions.json and session-registry.json"
LIVE="$HOME/hb"; mkdir -p "$LIVE"
RJ="$LIVE/q/session-registry.json"; SJ="$LIVE/q/sessions.json"
hb() { env SALA_HEARTBEAT_STATE_DIR="$LIVE" SALA_HEARTBEAT_LETTER=q SALA_HEARTBEAT_NAME=sbox SALA_SESSIONS=write "$SALA" heartbeat --no-push 2>&1; }
out=$(hb); rc=$?
[ "$rc" = 0 ] && [ -s "$SJ" ] && [ -s "$RJ" ] && ok "the heartbeat wrote sessions.json and session-registry.json" || bad "heartbeat rc=$rc: $out"
r=$(JQ '{k[:8]: sorted(v) for k, v in d.items()}' < "$SJ")
[ "$r" = '{"aaaaaaaa": ["machine", "name", "seen", "sleeping", "url"], "bbbbbbbb": ["machine", "name", "seen", "url"], "eeeeeeee": ["machine", "name", "seen", "url"]}' ] \
    && ok "sessions.json: alpha has a row (uuid key, sleeping added); beta's keys are as before; epsilon is live (one row, no sleeping); the stale marker (gamma) and the retired one made none" || bad "sessions.json rows: $r"
r=$(JQ '[d["'"$UA"'"]["name"], d["'"$UA"'"]["sleeping"], d["'"$UA"'"]["machine"]]' < "$SJ")
[ "$r" = '["alpha", "2026-11-22T06:10:00Z", "q"]' ] && ok "alpha's row: name, the marker's time, machine" || bad "alpha row: $r"
cp "$SJ" "$HOME/sj.1"; cp "$RJ" "$HOME/rj.1"; sleep 1.2
out=$(hb); rc=$?
same_file "$SJ" "$HOME/sj.1" && ok "a second run changes no byte of sessions.json (the sleeper's row keeps its seen)" || bad "sessions.json changed: $(diff "$HOME/sj.1" "$SJ" | head -6)"
r=$(JQ '{r["name"]: [r["state"], r.get("sleeping")] for r in d["sessions"].values()}' < "$RJ")
[ "$r" = '{"alpha": ["live", "2026-11-22T06:10:00Z"], "beta": ["live", null], "delta": ["retired", null]}' ] && ok "session-registry.json: sleeping on alpha only, state live; the retired row has none" || bad "registry rows: $r"
r=$(JQ '[sorted(r) for r in d["sessions"].values() if r["name"] == "beta"][0] == sorted(["id","name","aliases","project","project_key","role","lane","model","effort","pane","cwd","state","created","retired_at","transcripts"])' < "$RJ")
[ "$r" = true ] && ok "beta's published row has the contract's keys and no more" || bad "beta published keys"
rm -f "$SLP/$UA"; sleep 1.2; out=$(hb)   # a wake: the marker comes off
r=$(JQ 'sorted(k[:8] for k in d)' < "$SJ"); [ "$r" = '["bbbbbbbb", "eeeeeeee"]' ] && ok "after the wake alpha's row is gone from sessions.json (it has no live registry file yet)" || bad "after wake: $r"
r=$(JQ '[r.get("sleeping") for r in d["sessions"].values() if r["name"] == "alpha"]' < "$RJ"); [ "$r" = "[null]" ] && ok "after the wake alpha's registry row loses the key" || bad "after wake registry: $r"
out=$(env SALA_HEARTBEAT_STATE_DIR="$HOME/hb-off" SALA_HEARTBEAT_LETTER=q SALA_HEARTBEAT_NAME=sbox SALA_SESSIONS=off SALA_SLEEP_DIR="$HOME/none" "$SALA" heartbeat --no-push 2>&1); rc=$?
[ "$rc" = 0 ] && ! grep -q sleeping "$HOME/hb-off/q/sessions.json" && ok "no marker directory: no sleeping row, the heartbeat as before" || bad "no markers: rc=$rc $out"

echo "== the contract text and the teaching text"
C="$ROOT/docs/stackshot-contracts.md"
[ "$(sed -n 3p "$C")" = "contract-version: 53" ] && ok "docs/stackshot-contracts.md line 3: contract-version: 53" || bad "version line: $(sed -n 3p "$C")"
grep -q '^- \*\*51\*\*' "$C" && grep -q '^- \*\*52\*\*' "$C" && grep -q '^- \*\*53\*\*' "$C" && ! grep -q '^- \*\*54\*\*' "$C" && ok "changelog lines for 51 to 53, none for a later one" || bad "changelog"
grep -q '^| 35 | Sleeping sessions' "$C" && grep -q '^## 35\. Sleeping sessions' "$C" && ok "the index row and the section 35 exist" || bad "index row or section"
sec=$(awk '/^## 35\. Sleeping sessions/{p=1; next} /^## /{p=0} p' "$C")
for need in '$SALA_STATE_DIR/sleeping/<conversation uuid>' '<ISO-Z time> <name>' '`sessions.json`' '"sleeping"' 'sala sessions --json' 'sala op wake --only NAME' 'session-registry.json'; do
    has "$sec" "$need" && ok "interface 35 names: $need" || bad "interface 35 does not name: $need"
done
has "$sec" "--why" && has "$sec" "--words" && ok "interface 35 says both doors of the wake (the reason and the words)" || bad "the doors"
grep -q "Sleeping sessions" "$ROOT/docs/subcommands.md" && ok "docs/subcommands.md covers sleeping sessions" || bad "docs/subcommands.md"
grep -q 'sleeping' "$ROOT/lib/heartbeat.sh" && grep -q '"sleeping"' "$ROOT/lib/heartbeat.sh" && ok "the heartbeat's header names the sleeping key" || bad "heartbeat header"
run_help=$("$SALA" --help 2>&1 || true)
has "$run_help" '`sleeping`' && ok "sala --help: the sessions entry says what a sleeper shows" || bad "help: sessions entry lacks sleeping"

[ "$fail" = 0 ] && echo "sleepshow: pass" || echo "sleepshow: FAIL"
exit $fail
