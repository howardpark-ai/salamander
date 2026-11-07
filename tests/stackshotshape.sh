#!/usr/bin/env bash
# The shape of the three state files stackshot reads from sala: contract 12 of docs/stackshot-contracts.md (ruled
# Mon Oct 26th 2026) and its guard. stackshot reads them directly (its server.py `_lane_record`, `_limit_file`, `_lane_out`)
# for its `lane` done check and for deciding whether a pilot re-send waits, so a change to a row format or a key breaks it
# silently; this suite is where such a change fails first. Each file is written by sala's own writer and read back by a
# reader that copies stackshot's rule (the `read_lane` and `read_limit` functions below; if stackshot's rule changes, change
# them here and bump the contract):
#   · lanes.tsv: `<session>\t<lane>` rows (two or more tab fields, the session first, the lane second), sorted, one row per
#     session; a rename moves the row, a retire drops it, a session with no row falls to the first line of lane-default
#     beside it, and with neither file's row to `subscription-1`;
#   · lane-default: the default lane, alone on the first line;
#   · salamander-limit.json: an object whose `panes` map is keyed by the pane's transcript uuid, each value an object with
#     `s` (the tmux session), `lane`, `lim` (the limit named: seven_day, five_hour, seven_day_<model>, …), `since` and `reset`
#     (epoch seconds); a pane the watch stopped is in it, and a pane that is gone is dropped from it.
# The limit file is made by the real `watch --limit` against two fake claude panes (the compiled tests/fake-claude.c, a private
# tmux socket) whose transcripts carry the real weekly-limit record (tests/fixtures/limit-weekly.jsonl). Isolated HOME.
# Usage: bash tests/stackshotshape.sh   (exit 0 = pass; ~15 s)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_TZ ANTHROPIC_API_KEY ANTHROPIC_CUSTOM_HEADERS CLAUDE_CONFIG_DIR SALA_LANE_API_KEY_FILE SALA_LANE_TEAM_DIR SALA_MASTER
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_SESSIONS=off
P="$HOME/.claude/projects/x"; mkdir -p "$HOME/.claude/sessions" "$P" "$HOME/.local/bin" "$HOME/work"
touch "$HOME/.claude/salamander-rc.stopped"
cc -o "$HOME/.local/bin/claude" "$ROOT/tests/fake-claude.c" -lpthread || { rm -rf "$HOME"; exit 1; }   # the temp HOME goes with this exit (an EXIT trap may not exist yet here)
printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/systemctl"; chmod +x "$HOME/.local/bin/systemctl"   # no user units: nothing to re-run, no headless run to name
printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/journalctl"; chmod +x "$HOME/.local/bin/journalctl"
export PATH="$HOME/.local/bin:$PATH" FAKE_LOG="$HOME/fake.log" FAKE_SOCK_LOG="$HOME/sock.log"
export SALA_NOTIFY_CMD="cat >> $HOME/posts.txt" SALA_LIMIT_PSTART="*=0" SALA_LIMIT_CONFIRM=0
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT"
SALA="$ROOT/bin/salamander"; SOCK="sala-shape-$$"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"
cleanup() {
    local p; command tmux -L "$SOCK" kill-server 2>/dev/null; tmux_socket_rm; sleep 0.5
    for p in $(pgrep -x claude); do [ "$HOME/.local/bin/claude" -ef "/proc/$p/exe" ] && kill -9 "$p" 2>/dev/null; done
    rm -rf "$HOME" 2>/dev/null; true
}; trap cleanup EXIT
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux
. "$ROOT/lib/common.sh"
STATE="$HOME/.claude/salamander-limit.json"

# ---- the readers: stackshot's rules, copied (server.py _lane_record and _limit_file/_lane_out at stackshot main, Mon Oct 26th 2026)
read_lane() {  # <session> → the lane stackshot's _lane_record puts it on
    python3 - "$SALA_LANES" "$1" <<'PY'
import sys
from pathlib import Path
p, pane = Path(sys.argv[1]), sys.argv[2]
rows = p.read_text(encoding="utf-8").splitlines()
rec = ""
for ln in rows:
    parts = ln.rstrip("\r").split("\t")
    if len(parts) >= 2 and parts[0] == pane:
        rec = parts[1].strip(); break
if not rec:
    try:
        rec = (p.with_name("lane-default").read_text(encoding="utf-8").splitlines() or [""])[0].strip()
    except OSError:
        rec = ""
    rec = rec or "subscription-1"
print(rec)
PY
}
read_limit() {  # → "<uuid> <s> <lane> <lim> <since is int> <reset is int>" per stopped pane, as stackshot's _lane_out reads the file
    python3 - "$STATE" <<'PY'
import json, sys
panes = json.loads(open(sys.argv[1], encoding="utf-8").read()).get("panes") or {}
assert isinstance(panes, dict), "panes is not an object"
for u, v in sorted(panes.items(), key=lambda kv: str(kv[1].get("s"))):
    assert isinstance(v, dict), "a pane entry is not an object"
    print(u, v.get("s"), v.get("lane"), v.get("lim"), isinstance(v.get("since"), int), isinstance(v.get("reset"), int))
PY
}

echo "== lanes.tsv and lane-default: sala's writers, stackshot's reader"
KNOWN=$(printf '%s\n' $SALA_LANES_KNOWN | paste -sd' ')
[ ! -e "$SALA_LANES" ] && [ ! -e "$SALA_LANE_DEFAULT_FILE" ] && ok "no file yet" || bad "files before any write"
lane_write sala-test-b api; lane_write sala-test-a subscription-2; lane_write sala-test-c bedrock
[ "$(<"$SALA_LANES")" = "$(printf 'sala-test-a\tsubscription-2\nsala-test-b\tapi\nsala-test-c\tbedrock')" ] \
    && ok "rows are '<session>\\t<lane>', one per session, sorted" || bad "lanes.tsv: $(cat -A "$SALA_LANES")"
awk -F'\t' -v known=" $KNOWN " 'NF != 2 || $1 == "" || index(known, " " $2 " ") == 0 {bad=1} END {exit bad}' "$SALA_LANES" \
    && ok "every row has two fields, a session and a lane sala knows" || bad "a row outside the shape: $(cat -A "$SALA_LANES")"
[ "$(read_lane sala-test-a)" = subscription-2 ] && [ "$(read_lane sala-test-b)" = api ] && [ "$(read_lane sala-test-c)" = bedrock ] \
    && ok "stackshot's reader finds each session's own row" || bad "read: $(read_lane sala-test-a) $(read_lane sala-test-b) $(read_lane sala-test-c)"
[ "$(read_lane sala-test-none)" = subscription-1 ] && ok "no row and no lane-default: subscription-1" || bad "fallback: $(read_lane sala-test-none)"
lane_set_default api
[ "$(cat -A "$SALA_LANE_DEFAULT_FILE")" = 'api$' ] && ok "lane-default: the lane alone on the first line" || bad "lane-default: $(cat -A "$SALA_LANE_DEFAULT_FILE")"
[ "$(read_lane sala-test-none)" = api ] && [ "$(read_lane sala-test-a)" = subscription-2 ] && ok "a session with no row falls to the default; a row still wins" || bad "default: $(read_lane sala-test-none) $(read_lane sala-test-a)"
lane_rename sala-test-a sala-test-z
[ "$(read_lane sala-test-z)" = subscription-2 ] && [ "$(read_lane sala-test-a)" = api ] && ok "a rename moves the row (the old name falls to the default)" || bad "rename: z=$(read_lane sala-test-z) a=$(read_lane sala-test-a)"
lane_drop sala-test-z
[ "$(read_lane sala-test-z)" = api ] && ! grep -q . <(grep -F sala-test-z "$SALA_LANES") && ok "a retire drops the row" || bad "drop: $(read_lane sala-test-z); $(<"$SALA_LANES")"

# contract 12 (version 12, Mon Oct 26th 2026): the lane awsplatform is aws-platform. A writer records the new name for either spelling, so stackshot
# reads only the new one from a row written from now on; a row written before still says the old one until the next write or `sala lane --migrate`
lane_write sala-test-p aws-platform; lane_write sala-test-q awsplatform
[ "$(read_lane sala-test-p)" = aws-platform ] && [ "$(read_lane sala-test-q)" = aws-platform ] && ! grep -q awsplatform "$SALA_LANES" \
    && ok "aws-platform: lane_write records the new name for either spelling (stackshot reads aws-platform, never awsplatform, from a new row)" || bad "aws-platform rows: $(cat -A "$SALA_LANES")"
awk -F'\t' -v known=" $KNOWN " 'NF != 2 || index(known, " " $2 " ") == 0 {bad=1} END {exit bad}' "$SALA_LANES" && ok "and the new name is one of the lanes sala lists" || bad "aws-platform row outside the shape"
lane_drop sala-test-p; lane_drop sala-test-q

echo "== salamander-limit.json: the real watch --limit, two stopped panes, then one gone"
NOW=$(date +%s); RESET=$((NOW + 86400))
wk_rec() {  # <uuid> <epoch> <reset> <rateLimitType>: the real weekly-limit record, its resetsAt and type filled in
    sed -e "s|@UUID@|$(rid)|" -e "s|@TS@|$(iso "$2")|" -e "s|@CWD@|$HOME/work|" -e "s|@SESSION@|$1|" -e "s|@RESET@|$3|g" -e "s|@TYPE@|$4|g" \
        "$ROOT/tests/fixtures/limit-weekly.jsonl" >> "$P/$1.jsonl"; }
mk() { local n="sala-test-$1" u="$2"; shift 2
    tmux new-session -d -s "$n" -c "$HOME/work" -e FAKE_SESSION_ID="$u" -e FAKE_NAME="$n" -e FAKE_LOG="$FAKE_LOG" -e FAKE_SOCK_LOG="$FAKE_SOCK_LOG" "$@"
    tmux send-keys -t "$n" 'claude' Enter; }
UA=aaaaaaaa-0000-4000-8000-0000000000a1; UC=cccccccc-0000-4000-8000-0000000000c1
mk a "$UA"; mk c "$UC" -e CLAUDE_CONFIG_DIR="$HOME/.claude-team"
mkdir -p "$HOME/.claude-team"
fake_up sala-test-a sala-test-c || exit 1
wk_rec "$UA" $((NOW - 600)) "$RESET" seven_day
wk_rec "$UC" $((NOW - 500)) "$RESET" seven_day_opus
"$SALA" watch --limit >/dev/null 2>&1
[ -s "$STATE" ] && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert isinstance(d, dict) and isinstance(d.get("panes"), dict)' "$STATE" \
    && ok "the file is JSON with a 'panes' object" || bad "state: $(head -c 300 "$STATE" 2>&1)"
want=$(printf '%s\n' "$UA sala-test-a subscription-1 seven_day True True" "$UC sala-test-c subscription-2 seven_day_opus True True" | sort -k2)
[ "$(read_limit)" = "$want" ] && ok "each stopped pane: keyed by its transcript uuid, with s, lane, lim, since and reset (ints)" || bad "panes: $(read_limit)"
python3 -c 'import json,sys; p=json.load(open(sys.argv[1]))["panes"]; k=sys.argv[2].split(); assert p and all(v.get("rlane") in k for v in p.values()), p' "$STATE" "$KNOWN" \
    && ok "each stopped pane also carries rlane, the lane it runs on (interface 12, version 35)" || bad "rlane: $(head -c 300 "$STATE")"
tmux kill-session -t sala-test-c; sleep 0.5
"$SALA" watch --limit >/dev/null 2>&1
[ "$(read_limit)" = "$UA sala-test-a subscription-1 seven_day True True" ] && ok "a pane that is gone is dropped from 'panes'" || bad "after the kill: $(read_limit)"

[ "$fail" = 0 ] && echo "PASS" || echo "FAILED"
exit $fail
