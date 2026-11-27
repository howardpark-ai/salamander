#!/usr/bin/env bash
# `sala where` (lib/where.sh, lib/where.py): the box the owner works from right now, as a record plus one notice.
# Checks: a read with no record; set (a fleet name, case-insensitive; the record's four fields; one notice); the same box again only
# refreshes "at" and adds no second notice; a different box leaves exactly one where-notice (the old one dropped; other notices kept);
# an unknown box refused with the known names listed and nothing written; set with no fleet names file refused; the stale marker after
# 12 hours; --json with age_s; the time shown in KST whatever TZ is, in the plain line and in the notice; clear removes the record and its notice; the scan against a fake tmux,
# a fake tailscale and a fake environ folder (SALA_WHERE_ENVIRON_DIR): a new box from the newest client, an older client than the
# record ignored, a client idle for more than 10 minutes ignored, an unreadable or SSH_CONNECTION-less environ, an unknown address,
# no tmux and no tailscale all silent and change nothing; a plain read runs the scan first; `where seen` (the web UI's sighting: via web, same box
# refreshes, newest of ssh/web wins, a told record under 12 hours is kept, unknown/malformed/missing address records nothing); KST times; the usage text.
# Cleanup: the temporary folder is locked with flock while the suite runs and removed on exit, pass or fail. No process is started
# beyond the stand-ins, none is killed, and the tmux stand-in is a shell script (no tmux server is reached).
# Usage: bash tests/where.sh   (exit 0 = pass; seconds)
set -u
unset TMUX TMUX_PANE XDG_STATE_HOME SALA_STATE_DIR SALA_REG_DIR SALA_MACHINE_FOLLOW_MACHINES SALA_WHERE_ENVIRON_DIR
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
T=""
cleanup() { [ -z "$T" ] || { exec 8<&-; rm -rf "$T" 2>/dev/null; }; true; }; trap cleanup EXIT
T=$(mktemp -d "${TMPDIR:-/tmp}/where-XXXXXX")
exec 8< "$T"; flock -n 8 2>/dev/null
export HOME=$T/home SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC TZ=Etc/UTC TMUX_TMPDIR=$T/tmux SALA_AUTO_UPDATE=off PYTHONDONTWRITEBYTECODE=1
mkdir -p "$HOME" "$TMUX_TMPDIR" "$T/fleet" "$T/shim" "$T/environ" "$T/empty"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT"
SALA="$ROOT/bin/salamander"
ST="$HOME/.local/state/salamander"; REC="$ST/where.json"; NF="$ST/notices.tsv"
printf 'host-a\tbox-a\tA\nhost-b\tbox-b\tB\nhost-c\tbox-c\tC\n' > "$T/fleet/fleet-names.tsv"
export SALA_FLEET_NAMES="$T/fleet/fleet-names.tsv"
# stand-ins: tmux prints $T/clients (one "pid activity" a line) unless $T/notmux exists; tailscale prints $T/ts.json
cat > "$T/shim/tmux" <<'SH'
#!/bin/bash
[ "$1" = list-clients ] || exit 1
[ ! -e "$WHERE_T/notmux" ] || exit 1
cat "$WHERE_T/clients"
SH
cat > "$T/shim/tailscale" <<'SH'
#!/bin/bash
[ "$*" = "status --json" ] || exit 2
[ ! -e "$WHERE_T/nots" ] || exit 1
cat "$WHERE_T/ts.json"
SH
chmod +x "$T/shim/tmux" "$T/shim/tailscale"
export WHERE_T="$T"
export PATH="$T/shim:$PATH"
echo '{"Self":{"HostName":"host-a","TailscaleIPs":["198.51.100.1"]},"Peer":{"k1":{"HostName":"host-b","TailscaleIPs":["198.51.100.2"]},"k2":{"HostName":"host-c","TailscaleIPs":["198.51.100.3"]}}}' > "$T/ts.json"
: > "$T/clients"
export SALA_WHERE_ENVIRON_DIR="$T/environ"
NOW=$(date +%s)
count_notices() { local n=0 l; [ -s "$NF" ] && { while IFS= read -r l; do n=$((n + 1)); done < "$NF"; }; echo "$n"; }
field() { python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$REC" "$1"; }
setrec() {  # <box> <at> <via> <by>
    mkdir -p "$ST"; printf '{"box":"%s","at":%s,"via":"%s","by":"%s"}\n' "$1" "$2" "$3" "$4" > "$REC"; }
client() {  # <pid> <activity epoch> <SSH_CONNECTION or "-" for none>
    mkdir -p "$T/environ/$1"
    if [ "$3" = - ]; then printf 'HOME=/x\0' > "$T/environ/$1/environ"; else printf 'HOME=/x\0SSH_CONNECTION=%s 5555 203.0.113.9 22\0' "$3" > "$T/environ/$1/environ"; fi
    printf '%s %s\n' "$1" "$2" >> "$T/clients"; }

echo "== read with no record"
out=$("$SALA" where 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$out" = "no record" ] && ok "no record" || bad "no record: rc=$rc $out"
out=$("$SALA" where --json 2>&1); [ "$out" = null ] && ok "--json with no record is null" || bad "json none: $out"

echo "== set"
out=$("$SALA" where set Box-B --by sess-one 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(field box)" = box-b ] && [ "$(field via)" = told ] && [ "$(field by)" = sess-one ] && ok "set records box, via, by" || bad "set: rc=$rc $out"
[ "$(count_notices)" = 1 ] && ok "one notice" || bad "notices after set: $(count_notices)"
grep -q 'the owner is now on box-b (since ' "$NF" && grep -q 'Read it with sala where' "$NF" && ok "notice text" || bad "notice text: $(cat "$NF")"
out=$("$SALA" where); [[ $out == "the owner is on box-b (told by sess-one, "*" KST, just now)" ]] && ok "read line: $out" || bad "read line: $out"
out=$("$SALA" where --json); python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["box"]=="box-b" and d["age_s"]<5 and set(d)=={"box","at","via","by","age_s"}' "$out" && ok "--json has the record plus age_s" || bad "json: $out"
ls "$ST"/where.json.tmp.* >/dev/null 2>&1 && bad "temp file left behind" || ok "no temp file left behind"

echo "== the same box refreshes only"
setrec box-b $((NOW - 3000)) told sess-one
n0=$(count_notices)
"$SALA" where set box-b --by other >/dev/null 2>&1
[ "$(count_notices)" = "$n0" ] && ok "same box: no second notice" || bad "same box notices: $n0 -> $(count_notices)"
[ "$(field at)" -ge $((NOW - 5)) ] && [ "$(field by)" = sess-one ] && ok "same box: at refreshed, by kept" || bad "same box record: $(cat "$REC")"

echo "== a change replaces the notice"
"$SALA" notice add "an unrelated notice" --from tester >/dev/null
before=$(count_notices)
"$SALA" where set box-c --by sess-two >/dev/null 2>&1
after=$(count_notices)
[ "$after" = "$before" ] && [ "$(grep -c 'the owner is now on' "$NF")" = 1 ] && grep -q 'now on box-c' "$NF" && ! grep -q 'now on box-b' "$NF" && ok "one where-notice, the new one ($before -> $after)" || bad "change: $before -> $after: $(cat "$NF")"
grep -q 'an unrelated notice' "$NF" && ok "other notices kept" || bad "unrelated notice lost"
[ "$(field box)" = box-c ] && ok "record changed" || bad "record: $(cat "$REC")"

echo "== unknown box"
cp "$REC" "$T/rec.before"; before=$(count_notices)
out=$("$SALA" where set box-z 2>&1); rc=$?
[ "$rc" = 1 ] && [[ $out == *"box-a, box-b, box-c"* ]] && cmp -s "$REC" "$T/rec.before" && [ "$(count_notices)" = "$before" ] && ok "refused, known names listed, nothing changed" || bad "unknown: rc=$rc $out"
out=$("$SALA" where set 2>&1); [ $? = 2 ] && ok "set with no box: usage" || bad "no box: $out"
out=$(SALA_FLEET_NAMES= "$SALA" where set box-a 2>&1); rc=$?
[ "$rc" = 1 ] && [[ $out == *"SALA_FLEET_NAMES"* ]] && ok "no fleet names file: refused" || bad "no fleet file: rc=$rc $out"

echo "== stale and time zone"
setrec box-a $((NOW - 13 * 3600)) told sess-one
out=$("$SALA" where); [[ $out == *"13h ago) (stale)" ]] && ok "stale marker: $out" || bad "stale: $out"
setrec box-a $((NOW - 2 * 3600)) told sess-one
out=$("$SALA" where); [[ $out == *"2h ago)" ]] && [[ $out != *stale* ]] && ok "fresh: no marker" || bad "fresh: $out"
setrec box-a 1700000000 told ""
out=$(TZ=Asia/Seoul "$SALA" where); [[ $out == *"(told, 07:13 KST, "* ]] && ok "time in KST" || bad "kst: $out"
out=$(TZ=Etc/UTC "$SALA" where); [[ $out == *"(told, 07:13 KST, "* ]] && [[ $out != *UTC* ]] && ok "same under TZ=UTC: KST, no UTC" || bad "utc: $out"
out=$(TZ=America/New_York "$SALA" where); [[ $out == *"(told, 07:13 KST, "* ]] && ok "same under another TZ" || bad "ny: $out"
echo "-- the notice carries the KST time too"
"$SALA" where clear >/dev/null 2>&1
python3 -I -S -c 'import sys; sys.path.insert(0, sys.argv[1]); import where; where.post_notice("box-a", 1700000000)' "$ROOT/lib" >/dev/null 2>&1
grep -q 'the owner is now on box-a (since 07:13 KST)' "$NF" && ! grep -q 'UTC' "$NF" && ok "notice: since 07:13 KST, no UTC" || bad "notice time: $(cat "$NF" 2>/dev/null)"
TZ=Etc/UTC python3 -I -S -c 'import sys; sys.path.insert(0, sys.argv[1]); import where; assert where.clock(1700000000) == "07:13 KST"' "$ROOT/lib" && ok "clock() ignores TZ" || bad "clock under UTC"
"$SALA" where clear >/dev/null 2>&1

echo "== clear"
"$SALA" where set box-a >/dev/null 2>&1
"$SALA" where clear >/dev/null 2>&1
[ ! -e "$REC" ] && ! grep -q 'the owner is now on' "$NF" 2>/dev/null && grep -q 'an unrelated notice' "$NF" && ok "clear removes record and its notice only" || bad "clear: $(cat "$NF" 2>/dev/null)"
[ "$("$SALA" where)" = "no record" ] && ok "read after clear" || bad "after clear"

echo "== scan"
"$SALA" where clear >/dev/null 2>&1; before=$(count_notices)
: > "$T/clients"; client 4001 $((NOW - 30)) 198.51.100.2
out=$("$SALA" where --scan); rc=$?
[ "$rc" = 0 ] && [ "$(field box)" = box-b ] && [ "$(field via)" = ssh ] && [ "$(field by)" = "" ] && ok "scan records the ssh client's box: $out" || bad "scan: rc=$rc $out $(cat "$REC" 2>/dev/null)"
[ "$(count_notices)" = $((before + 1)) ] && ok "scan adds one notice" || bad "scan notices"
out=$("$SALA" where); [[ $out == "the owner is on box-b (seen over ssh, "* ]] && ok "read line for ssh: $out" || bad "ssh line: $out"
echo "-- the newest client wins"
: > "$T/clients"; client 4002 $((NOW - 200)) 198.51.100.3; client 4003 $((NOW - 20)) 198.51.100.1
"$SALA" where --scan >/dev/null; [ "$(field box)" = box-a ] && [ "$(count_notices)" = $((before + 1)) ] && ok "newest client, still one where-notice" || bad "newest: $(cat "$REC")"
echo "-- activity older than the record is ignored"
setrec box-b $((NOW - 5)) told s
: > "$T/clients"; client 4004 $((NOW - 100)) 198.51.100.3
"$SALA" where --scan >/dev/null; [ "$(field box)" = box-b ] && [ "$(field via)" = told ] && ok "older activity changes nothing" || bad "older: $(cat "$REC")"
echo "-- the same box with newer activity refreshes at"
setrec box-b $((NOW - 500)) told s
: > "$T/clients"; client 4005 $((NOW - 100)) 198.51.100.2
n0=$(count_notices); "$SALA" where --scan >/dev/null
[ "$(field box)" = box-b ] && [ "$(field at)" -ge $((NOW - 101)) ] && [ "$(field via)" = told ] && [ "$(count_notices)" = "$n0" ] && ok "same box: at refreshed, no notice" || bad "same: $(cat "$REC")"
echo "-- silent failures change nothing"
setrec box-b $((NOW - 1000)) told s; cp "$REC" "$T/rec.before"; n0=$(count_notices)
silent() {  # <label>: run the scan, expect exit 0, no output, record and notices unchanged
    out=$("$SALA" where --scan 2>&1); rc=$?
    [ "$rc" = 0 ] && [ -z "$out" ] && cmp -s "$REC" "$T/rec.before" && [ "$(count_notices)" = "$n0" ] && ok "$1" || bad "$1: rc=$rc out=$out"; }
: > "$T/clients"; client 4010 $((NOW - 700)) 198.51.100.3; silent "client idle more than 10 minutes"
: > "$T/clients"; client 4011 $((NOW - 10)) -; silent "environ without SSH_CONNECTION"
: > "$T/clients"; printf '4012 %s\n' $((NOW - 10)) >> "$T/clients"; silent "environ unreadable"
: > "$T/clients"; client 4013 $((NOW - 10)) 198.51.100.99; silent "address no tailnet node has"
: > "$T/clients"; client 4014 $((NOW - 10)) 198.51.100.3; touch "$T/nots"; PATH="$T/shim:$PATH" silent "tailscale fails"
rm -f "$T/nots"; touch "$T/notmux"; silent "tmux fails"; rm -f "$T/notmux"
printf 'not a line\n' > "$T/clients"; silent "junk from tmux"
: > "$T/clients"; silent "no clients"
echo '{"Peer":{"k":{"HostName":"host-unlisted","TailscaleIPs":["198.51.100.7"]}}}' > "$T/ts.json"
: > "$T/clients"; client 4015 $((NOW - 10)) 198.51.100.7; silent "a node the fleet names file does not list"
echo '{"Self":{"HostName":"host-a","TailscaleIPs":["198.51.100.1"]},"Peer":{"k1":{"HostName":"host-b","TailscaleIPs":["198.51.100.2"]},"k2":{"HostName":"host-c","TailscaleIPs":["198.51.100.3"]}}}' > "$T/ts.json"
echo "-- no tmux and no tailscale on the PATH at all"
out=$(PATH="$T/empty:/usr/bin:/bin" "$SALA" where --scan 2>&1); rc=$?
[ "$rc" = 0 ] && cmp -s "$REC" "$T/rec.before" && ok "neither program installed: silent" || bad "no programs: rc=$rc $out"
echo "-- a plain read runs the scan first"
setrec box-a $((NOW - 1000)) told s
: > "$T/clients"; client 4020 $((NOW - 10)) 198.51.100.3
out=$("$SALA" where); [[ $out == "the owner is on box-c (seen over ssh, "* ]] && ok "plain read scans first" || bad "plain read: $out"

echo "== seen (the web UI's sighting, via web)"
"$SALA" where clear >/dev/null 2>&1; before=$(count_notices)
out=$("$SALA" where seen 198.51.100.2); rc=$?
[ "$rc" = 0 ] && [ "$(field box)" = box-b ] && [ "$(field via)" = web ] && [ "$(field by)" = "" ] && [ "$(count_notices)" = $((before + 1)) ] && ok "a known address records its box via web, one notice: $out" || bad "seen: rc=$rc $out $(cat "$REC" 2>/dev/null)"
out=$("$SALA" where); [[ $out == "the owner is on box-b (seen in the web UI, "* ]] && ok "read line for web: $out" || bad "web line: $out"
echo "-- the same box refreshes only"
setrec box-b $((NOW - 500)) web ""; n0=$(count_notices)
"$SALA" where seen 198.51.100.2 >/dev/null
[ "$(field box)" = box-b ] && [ "$(field at)" -ge $((NOW - 5)) ] && [ "$(count_notices)" = "$n0" ] && ok "same box: at refreshed, no notice" || bad "seen same: $(cat "$REC")"
echo "-- ssh and web are equals: the newest wins"
setrec box-a $((NOW - 100)) ssh ""
"$SALA" where seen 198.51.100.3 >/dev/null
[ "$(field box)" = box-c ] && [ "$(field via)" = web ] && ok "a web sighting replaces an older ssh record" || bad "web over ssh: $(cat "$REC")"
setrec box-a $((NOW - 100)) web ""
"$SALA" where seen 198.51.100.3 >/dev/null
[ "$(field box)" = box-c ] && [ "$(field via)" = web ] && ok "a web sighting replaces an older web record" || bad "web over web: $(cat "$REC")"
echo "-- a told record under 12 hours old wins; a stale one does not"
setrec box-a $((NOW - 3600)) told sess-one; cp "$REC" "$T/rec.before"; n0=$(count_notices)
"$SALA" where seen 198.51.100.3 >/dev/null
cmp -s "$REC" "$T/rec.before" && [ "$(count_notices)" = "$n0" ] && ok "told within its window is not overwritten" || bad "told kept: $(cat "$REC")"
setrec box-a $((NOW - 13 * 3600)) told sess-one
"$SALA" where seen 198.51.100.3 >/dev/null
[ "$(field box)" = box-c ] && [ "$(field via)" = web ] && ok "a stale told record is replaced" || bad "told stale: $(cat "$REC")"
echo "-- nothing recorded: an unknown, a malformed or a missing address"
setrec box-a $((NOW - 1000)) ssh ""; cp "$REC" "$T/rec.before"; n0=$(count_notices)
unchanged() {  # <label> <args...>: run `where seen`, expect exit 0, no output, record and notices unchanged
    local label=$1; shift
    out=$("$SALA" where seen "$@" 2>&1); rc=$?
    [ "$rc" = 0 ] && [ -z "$out" ] && cmp -s "$REC" "$T/rec.before" && [ "$(count_notices)" = "$n0" ] && ok "$label" || bad "$label: rc=$rc out=$out"; }
unchanged "an address no machine has (a phone, a public address)" 203.0.113.50
unchanged "not an address" not-an-ip
unchanged "an empty address" ""
touch "$T/nots"; unchanged "tailscale fails and the machine list has no address" 198.51.100.3; rm -f "$T/nots"
out=$("$SALA" where seen 2>&1); [ $? = 2 ] && ok "seen with no address: usage" || bad "seen usage: $out"
rm -f "$REC"; "$SALA" where seen 203.0.113.50 >/dev/null; [ ! -e "$REC" ] && ok "an unknown address records nothing" || bad "unknown wrote a record"

echo "== usage"
out=$("$SALA" where --help); [[ $out == *"sala where set <box>"* ]] && [[ $out == *"--scan"* ]] && ok "where --help" || bad "help: $out"
out=$("$SALA" where bogus 2>&1); [ $? = 2 ] && ok "unknown argument: exit 2" || bad "bogus: $out"

echo; [ "$fail" = 0 ] && echo "where: pass" || echo "where: FAIL"
exit $fail
