#!/usr/bin/env bash
# Inbox holds and the waiting-line check through the stackshot server (lib/inboxhold.py; lib/common.sh inbox_hold, inbox_touch, inbox_release, inbox_release_orphans,
# inbox_mode_r; lib/wrapup.sh inbox_line_waiting, wake_candidates; docs/stackshot-contracts.md interface 3). On the box that runs stackshot's server these are files; on
# another box the same four things are calls to the server's client API. The client is a fake (tests/fake-inbox-client.py: answers the four calls from files, logs every
# call, fails on demand in the ways a server fails), in an isolated HOME and a temporary folder, no tmux, no network. Checked:
#   the mode: files and server as set (SALA_INBOX_MODE, an override); the default (auto) is the stackshot client's own setting: $ANCHOR_PUSH_MODE, else [client] push_mode of its
#     config (local = files, server = server, auto = the URL rule), read from the client's checkout or, with no client, from the config file; the URL rule is server when the client's
#     URL ($STACKSHOT_URL, else what the client itself resolves, else the config file's [client] url) names another machine, files for a loopback host, this box's own name or no URL;
#   server mode: hold is `post inbox-hold KEY KEY --minutes 10` (SALA_INBOX_HOLD_MINUTES), a touch is the same call again with a later time and one ledger row, a release is
#     `post inbox-release KEY KEY` and drops the row, the hold folder is never touched, `wait` still waits for the resumed conversation;
#   minutes 0: the server refuses it (the fake does too), so a 0 or a negative or odd SALA_INBOX_HOLD_MINUTES goes out as 1440 or 10 and no call ever carries 0;
#   files mode: the files as before, the fake never called; auto with a loopback URL is files, with another host's server;
#   THE FAIL-SAFE: a server that is down, hangs (cut at SALA_INBOX_TIMEOUT), answers 500 or 401 or something that is not JSON, or lists no key as held is NO ANSWER: inbox_hold
#     returns 1 and says why, its ledger row stays, a release that was not answered keeps its row, a touch that was not answered still returns 0, after one no answer the shell
#     does not ask again for SALA_INBOX_BREAKER s; inbox_line_waiting says "a line waits" (0) with INBOX_WAIT_UNKNOWN=1, never "nothing waits"; wake_candidates lists nobody for it;
#   a 400 is the server's refusal (a bad key, kind or time, the 500-key cap), no answer, never "no such call": no fallback to the files;
#   exit code 4 of the client (a delivery error a later try can get past): the call is made once more; a second 4 is no answer that does not start the breaker;
#   a server without the call (404, a client that prints its usage): the hold falls back to the files when this box has the hold folder, and is no answer when it has not;
#     the waiting check looks into the inbox folder here when there is one and is no answer when there is not;
#   held_elsewhere: a release names the keys another tool's file (a file hold, a reboot's resume) still holds; they are left, said, and no failure;
#   the waiting check: `get inbox-waiting NAME,UUID`, hub or msg, held or not, a line for a longer name is no line, a missing uuid is left out;
#   the orphans in server mode: the API holds with no time of their own and no ledger row, seen for SALA_INBOX_ORPHAN_SECS, are released (in calls of at most 20 keys); a hold with its
#     own time (made through the server, maybe by another box), another tool's file hold and a reboot's resume hold are never freed; a list or a release that is not answered frees nothing
#     and forgets nothing.
# SAFETY: no kill, no pkill, no tmux, no process is started but the fake client and the helper; HOME and every file are in one mktemp -d, held with flock and removed on exit.
# Usage: bash tests/inboxserver.sh   (exit 0 = pass; about 15 seconds)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/sala-inboxserver.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
exec 7< "$T"; flock -n 7 2>/dev/null   # systemd-tmpfiles' ageing skips a directory held with flock (fd 8 is the hold lock's)
export HOME="$T/home"; mkdir -p "$HOME/.claude"
unset XDG_STATE_HOME XDG_CONFIG_HOME TMUX TMUX_PANE STACKSHOT_URL STACKSHOT_CONFIG ANCHOR_PUSH_MODE FAKE_SS_PUSH_MODE FAKE_SS_URL SALA_STACKSHOT_DIR SALA_STACKSHOT_INBOX
export SALA_CONFIG=/dev/null SALA_ROOT="$ROOT" SALA_INBOX_HOLD_DIR="$T/hold" FAKE_INBOX_DIR="$T/fake" SALA_INBOX_TIMEOUT=2 SALA_INBOX_BREAKER=0
FC="$ROOT/tests/fake-inbox-client.py"; export SALA_STACKSHOT_CLIENT="$FC"
. "$ROOT/lib/common.sh"; . "$ROOT/lib/wrapup.sh"
LEDGER="$SALA_INBOX_LEDGER"; SEEN="$SALA_STATE_DIR/inbox-held-unaccounted.tsv"; CALLS="$FAKE_INBOX_DIR/calls.log"; HOLDS="$FAKE_INBOX_DIR/holds.json"
case "$LEDGER" in "$T"/*) ;; *) bad "the ledger is outside the sandbox: $LEDGER"; exit 1 ;; esac
case "$SEEN" in "$T"/*) ;; *) bad "the first-seen file is outside the sandbox: $SEEN"; exit 1 ;; esac
U1=11111111-0000-4000-8000-000000000001 N1=sala-test-one U2=22222222-0000-4000-8000-000000000002 N2=sala-test-two
REMOTE=https://stackshot.remote.example.test
reset() { rm -rf "$FAKE_INBOX_DIR" "$SALA_INBOX_HOLD_DIR" "$SEEN"; mkdir -p "$FAKE_INBOX_DIR/inbox/hub" "$FAKE_INBOX_DIR/inbox/msg" "$(dirname "$LEDGER")"; : > "$LEDGER"; unset FAKE_INBOX_FAIL FAKE_INBOX_HOW; _INBOX_DOWN=0; INBOX_WHY=""; INBOX_ORPHANS_FREED=(); }
ncalls() { [ -f "$CALLS" ] && wc -l < "$CALLS" || echo 0; }
lastcall() { [ -f "$CALLS" ] && tail -n 1 "$CALLS"; }
fkey() { python3 -c 'import json, sys
d = json.load(open(sys.argv[1])); print(sum(1 for s in d.values() for r in s if r["key"] == sys.argv[2] and r["origin"] == "api"))' "$HOLDS" "$1" 2>/dev/null || echo 0; }   # how many sources hold the key through the API on the fake server
forigin() { python3 -c 'import json, sys
d = json.load(open(sys.argv[1])); print(sum(1 for s in d.values() for r in s if r["key"] == sys.argv[2] and r["origin"] == sys.argv[3]))' "$HOLDS" "$1" "$2" 2>/dev/null || echo 0; }   # how many sources hold the key with that origin (file, resume)
fexp() { python3 -c 'import json, sys
d = json.load(open(sys.argv[1])); print(int(next(r["expires"] for r in d["msg"] if r["key"] == sys.argv[2] and r["origin"] == "api") or 0))' "$HOLDS" "$1" 2>/dev/null || echo 0; }
fseed() { python3 -c 'import json, sys
a = sys.argv; d = {"msg": [], "hub": []}
for spec in a[2:]:
    key, origin, exp = spec.split(":")
    for s in ("msg", "hub"): d[s].append({"key": key, "origin": origin, "since": (1 if origin == "api" else None), "expires": (float(exp) if exp != "-" else None)})
json.dump(d, open(a[1], "w"))' "$HOLDS" "$@"; }   # <key:origin:expires|-> … → the fake server's holds (a key may be given twice with two origins)
lines() { awk 'END {print NR + 0}' "$1" 2>/dev/null; }
rows() { awk 'END {print NR + 0}' "$LEDGER" 2>/dev/null; }   # the ledger's lines
now() { printf '%(%s)T' -1; }
helper() { SALA_INBOX_CLIENT=${SALA_INBOX_CLIENT-$FC} python3 -I -S "$ROOT/lib/inboxhold.py" "$@"; }   # the fake client unless a test names another (or an empty one: none)

echo "== the mode: files and server as set; auto by the client's URL"
reset
r=$(SALA_INBOX_MODE=files STACKSHOT_URL=$REMOTE helper mode); [ "$r" = files ] && ok "SALA_INBOX_MODE=files is files, whatever the URL" || bad "files: $r"
r=$(SALA_INBOX_MODE=server STACKSHOT_URL=http://127.0.0.1:8 helper mode); [ "$r" = server ] && ok "SALA_INBOX_MODE=server is server, whatever the URL" || bad "server: $r"
r=$(unset SALA_INBOX_MODE; STACKSHOT_URL=$REMOTE helper mode); [ "$r" = server ] && ok "no setting is auto: a URL that names another machine is server" || bad "default: $r"
for u in http://127.0.0.1:8080 http://localhost:8080 "http://[::1]:8080" http://127.1.2.3/x "http://$(hostname):8080" "http://$(hostname | tr a-z A-Z)" "$(hostname)"; do
    r=$(SALA_INBOX_MODE=auto STACKSHOT_URL=$u helper mode); [ "$r" = files ] && ok "auto: $u is this box (loopback or its own name): files" || bad "auto $u: $r"
done
for u in https://stackshot.remote.example.test http://203.0.113.9:8080 "http://other-$(hostname):1" stackshot.remote.example.test; do
    r=$(SALA_INBOX_MODE=auto STACKSHOT_URL=$u helper mode); [ "$r" = server ] && ok "auto: $u names another machine: server" || bad "auto $u: $r"
done
r=$(SALA_INBOX_MODE=auto helper mode); [ "$r" = files ] && ok "auto with no URL known anywhere: files (the one-box setup)" || bad "auto no URL: $r"
r=$(SALA_INBOX_MODE=nonsense STACKSHOT_URL=$REMOTE helper mode 2>"$T/err"); [ "$r" = server ] && grep -q 'taken as auto' "$T/err" && ok "a setting that is none of the three is read as auto, and says so" || bad "nonsense: $r $(cat "$T/err")"
printf '[client]\nurl = "%s"\n' "$REMOTE" > "$T/cfg.toml"
r=$(SALA_INBOX_MODE=auto STACKSHOT_CONFIG=$T/cfg.toml helper mode); [ "$r" = server ] && ok "auto with no client to ask reads [client] url of the config file" || bad "config: $r"
printf '[client]\nurl = "http://localhost:9"\n' > "$T/cfg.toml"
r=$(SALA_INBOX_MODE=auto STACKSHOT_CONFIG=$T/cfg.toml helper mode); [ "$r" = files ] && ok "a loopback URL in the config file is files" || bad "config loopback: $r"
# the client's own resolution: a stand-in stackshot checkout whose client.py answers server_url()
SS="$T/ss"; mkdir -p "$SS/stackshot/core" "$SS/stackshot/fleet"; : > "$SS/stackshot/__init__.py"; : > "$SS/stackshot/core/__init__.py"; : > "$SS/stackshot/fleet/__init__.py"
printf 'import os\ndef get(*keys, default=None):\n    return os.environ["FAKE_SS_PUSH_MODE"]   # unset: the stand-in has no [client] push_mode to read (the client'"'"'s own default is local)\n' > "$SS/stackshot/core/config.py"
printf 'import os\ndef server_url():\n    return os.environ.get("FAKE_SS_URL", "")\n' > "$SS/stackshot/fleet/client.py"
r=$(SALA_INBOX_CLIENT="$SS/stackshot/fleet/client.py" FAKE_SS_URL=$REMOTE SALA_INBOX_MODE=auto helper mode); [ "$r" = server ] && ok "auto asks the client's own server_url(): another machine is server" || bad "client url: $r"
r=$(SALA_INBOX_CLIENT="$SS/stackshot/fleet/client.py" FAKE_SS_URL=http://localhost:5 SALA_INBOX_MODE=auto helper mode); [ "$r" = files ] && ok "the client's own loopback URL is files" || bad "client loopback: $r"
r=$(SALA_INBOX_CLIENT="$SS/stackshot/fleet/client.py" FAKE_SS_URL=$REMOTE STACKSHOT_URL=http://localhost:5 SALA_INBOX_MODE=auto helper mode); [ "$r" = files ] && ok "\$STACKSHOT_URL wins over what the client resolves (as the client itself does)" || bad "env wins: $r"
unset FAKE_SS_URL
echo "-- the client's own [client] push_mode decides, so a box has one setting: local = files, server = server, auto = the URL rule"
C="$SS/stackshot/fleet/client.py"; export SALA_INBOX_MODE=auto   # (tests/lib.sh pins files for the other suites)
for pm in local server auto; do
    for u in $REMOTE http://localhost:5; do
        r=$(SALA_INBOX_CLIENT=$C FAKE_SS_PUSH_MODE=$pm FAKE_SS_URL=$u helper mode)
        case "$pm/$u" in local/*) w=files ;; server/*) w=server ;; "auto/$REMOTE") w=server ;; *) w=files ;; esac
        [ "$r" = "$w" ] && ok "push_mode=$pm, client URL $u: $w" || bad "push_mode=$pm url=$u: $r (wanted $w)"
    done
done
r=$(SALA_INBOX_CLIENT=$C FAKE_SS_PUSH_MODE=server FAKE_SS_URL=http://localhost:5 SALA_INBOX_MODE=files helper mode); [ "$r" = files ] && ok "SALA_INBOX_MODE=files overrides push_mode=server" || bad "override files: $r"
r=$(SALA_INBOX_CLIENT=$C FAKE_SS_PUSH_MODE=local FAKE_SS_URL=$REMOTE SALA_INBOX_MODE=server helper mode); [ "$r" = server ] && ok "SALA_INBOX_MODE=server overrides push_mode=local" || bad "override server: $r"
r=$(SALA_INBOX_CLIENT=$C FAKE_SS_PUSH_MODE=server FAKE_SS_URL=$REMOTE ANCHOR_PUSH_MODE=local helper mode); [ "$r" = files ] && ok "\$ANCHOR_PUSH_MODE wins over the config's push_mode (as it does for push.py)" || bad "anchor env: $r"
r=$(SALA_INBOX_CLIENT=$C FAKE_SS_PUSH_MODE=bogus FAKE_SS_URL=$REMOTE helper mode 2>"$T/err"); [ "$r" = server ] && grep -q 'push_mode' "$T/err" && ok "a push_mode that is none of the three is read as auto, and says so" || bad "bogus push_mode: $r $(cat "$T/err")"
r=$(SALA_INBOX_CLIENT=$C FAKE_SS_URL=$REMOTE helper mode); [ "$r" = server ] && ok "a client that cannot say its push_mode: the URL rule alone" || bad "no push_mode: $r"
printf '[client]\nurl = "%s"\npush_mode = "local"\n' "$REMOTE" > "$T/cfg.toml"
r=$(STACKSHOT_CONFIG=$T/cfg.toml helper mode); [ "$r" = files ] && ok "no client to ask: push_mode of the config file (local is files, whatever the URL)" || bad "toml local: $r"
printf '[client]\nurl = "http://localhost:9"\npush_mode = "server"\n' > "$T/cfg.toml"
r=$(STACKSHOT_CONFIG=$T/cfg.toml helper mode); [ "$r" = server ] && ok "no client to ask: push_mode = server in the config file is server" || bad "toml server: $r"
export SALA_INBOX_MODE=auto SALA_STACKSHOT_CLIENT="$C" FAKE_SS_URL=$REMOTE FAKE_SS_PUSH_MODE=local; inbox_mode_r m1; export FAKE_SS_PUSH_MODE=server; _INBOX_MODE_KEY=; inbox_mode_r m2   # (the config's own change is not in the cache key: a process reads it once)
[ "$m1/$m2" = files/server ] && ok "inbox_mode_r follows the client's push_mode through the shell" || bad "inbox_mode_r push_mode: $m1/$m2"
export ANCHOR_PUSH_MODE=local; inbox_mode_r m3; unset ANCHOR_PUSH_MODE FAKE_SS_URL FAKE_SS_PUSH_MODE; _INBOX_MODE_KEY=
[ "$m3" = files ] && ok "and a change of \$ANCHOR_PUSH_MODE (it is in the cache key)" || bad "inbox_mode_r anchor env: $m3"
export SALA_STACKSHOT_CLIENT="$FC"
export SALA_INBOX_MODE=auto STACKSHOT_URL=http://127.0.0.1:1; inbox_mode_r m1; export STACKSHOT_URL=$REMOTE; inbox_mode_r m2
[ "$m1/$m2" = files/server ] && ok "inbox_mode_r follows a change of URL inside one shell (the cache is keyed on it)" || bad "inbox_mode_r: $m1/$m2"
unset STACKSHOT_URL

echo "== server mode: hold, touch and release are the client's calls; the hold folder is never touched"
reset; export SALA_INBOX_MODE=server
inbox_hold "$U1" "$N1"; rc=$?
[ "$rc" = 0 ] && [ "$(lastcall)" = "post inbox-hold $U1 $N1 --minutes 10" ] && ok "inbox_hold: post inbox-hold <uuid> <name> --minutes 10, exit 0" || bad "hold: rc=$rc call=$(lastcall)"
[ "$(fkey "$U1")" = 2 ] && [ "$(fkey "$N1")" = 2 ] && ok "both keys are held in both sources on the server" || bad "server holds: $(cat "$HOLDS")"
[ "$(rows)" = 1 ] && grep -q "$U1" "$LEDGER" && ok "the ledger has its row (sala's own record, as in files mode)" || bad "ledger: $(cat "$LEDGER")"
[ ! -e "$SALA_INBOX_HOLD_DIR" ] && ok "no hold folder was made" || bad "the hold folder exists"
e1=$(fexp "$U1"); [ "$e1" -ge $(( $(now) + 590 )) ] && [ "$e1" -le $(( $(now) + 610 )) ] && ok "it expires in about 10 minutes" || bad "expires $e1 vs $(now)"
sleep 1.1; inbox_touch "$U1" "$N1"; rc=$?
e2=$(fexp "$U1"); [ "$rc" = 0 ] && [ "$(lastcall)" = "post inbox-hold $U1 $N1 --minutes 10" ] && [ "$e2" -gt "$e1" ] && [ "$(ncalls)" = 2 ] && ok "inbox_touch: the same call again, the server's time moves on" || bad "touch: rc=$rc e1=$e1 e2=$e2 calls=$(ncalls)"
[ "$(rows)" = 1 ] && ok "the touch left one ledger row (replaced, not added)" || bad "ledger after touch: $(cat "$LEDGER")"
SALA_INBOX_HOLD_MINUTES=25 inbox_hold "$U2" "$N2"; [ "$(lastcall)" = "post inbox-hold $U2 $N2 --minutes 25" ] && ok "SALA_INBOX_HOLD_MINUTES sets the time asked for" || bad "minutes: $(lastcall)"
echo "-- minutes 0 is refused by the server: sala never sends it"
for spec in "0:1440" "-4:10" "abc:10" "99999:1440" "1440:1440" "0.5:0.5" ":10"; do
    mv_=${spec%%:*}; want=${spec#*:}
    SALA_INBOX_HOLD_MINUTES=$mv_ inbox_touch "$U2" "$N2" 2>/dev/null; rc=$?
    [ "$rc" = 0 ] && [ "$(lastcall)" = "post inbox-hold $U2 $N2 --minutes $want" ] && ok "SALA_INBOX_HOLD_MINUTES='$mv_' goes out as --minutes $want" || bad "minutes '$mv_': rc=$rc call=$(lastcall) (wanted $want)"
done
! grep -qE -- '--minutes 0$' "$CALLS" && ok "no call of this run ever carried --minutes 0" || bad "a call carried minutes 0"
python3 "$FC" post inbox-hold "$U2" --minutes 0 2>"$T/err"; rc=$?
[ "$rc" = 1 ] && grep -q '\[400\]' "$T/err" && ok "the fake refuses --minutes 0 as the server does (400), so the checks above prove sala never asks for it" || bad "the fake accepted 0: rc=$rc $(cat "$T/err")"
helper hold 0 "$U2" "$N2"; rc=$?; [ "$rc" = 0 ] && [ "$(lastcall)" = "post inbox-hold $U2 $N2 --minutes 1440" ] && ok "the helper itself turns a 0 into the longest hold" || bad "helper 0: rc=$rc $(lastcall)"
live_pane_for_uuid() { echo "%1 x"; }; session_socket() { echo /s; }   # the resumed conversation is up at once: `wait` has nothing to wait for
SECONDS=0; inbox_release "$U1" "$N1" wait; rc=$?
[ "$rc" = 0 ] && [ "$(lastcall)" = "post inbox-release $U1 $N1" ] && [ "$(fkey "$U1")" = 0 ] && [ "$(fkey "$N1")" = 0 ] && [ "$(fkey "$U2")" = 2 ] && ok "inbox_release (with wait): post inbox-release <uuid> <name>; those keys are gone from the server, the other hold stays" || bad "release: rc=$rc call=$(lastcall) $(cat "$HOLDS")"
[ "$(rows)" = 1 ] && ! grep -q "$U1" "$LEDGER" && grep -q "$U2" "$LEDGER" && ok "its ledger row is gone, the other's stays" || bad "ledger after release: $(cat "$LEDGER")"
unset -f live_pane_for_uuid session_socket; . "$ROOT/lib/common.sh"
inbox_hold "" ""; rc=$?; [ "$rc" = 0 ] && ok "a hold with no keys at all is nothing to ask the server" || bad "no keys: rc=$rc"
inbox_holding && ok "inbox_holding: a hold can be made (server mode, no hold folder needed)" || bad "inbox_holding"
export SALA_INBOX_MODE=files; inbox_holding && bad "inbox_holding in files mode without the folder" || ok "inbox_holding in files mode follows the folder: none, so no hold"

echo "== files mode: the files as before, the server never asked"
reset; export SALA_INBOX_MODE=files; mkdir -p "$SALA_INBOX_HOLD_DIR"
inbox_hold "$U1" "$N1"; rc=$?
[ "$rc" = 0 ] && grep -qxF "$U1" "$SALA_INBOX_HOLD_DIR/held-msg.txt" && grep -qxF "$N1" "$SALA_INBOX_HOLD_DIR/held-hub.txt" && [ "$(rows)" = 1 ] && ok "inbox_hold wrote the keys into both held files and the ledger" || bad "files hold: rc=$rc"
inbox_touch "$U1" "$N1"; inbox_release "$U1" "$N1"
[ ! -s "$SALA_INBOX_HOLD_DIR/held-msg.txt" ] && [ ! -s "$SALA_INBOX_HOLD_DIR/held-hub.txt" ] && [ "$(rows)" = 0 ] && ok "touch and release as before: the files and the ledger are empty again" || bad "files release"
inbox_line_waiting x y; rc=$?; [ "$rc" = 1 ] && ok "inbox_line_waiting looks into the inbox folder (none: nothing waits)" || bad "files waiting: rc=$rc"
[ ! -e "$CALLS" ] && ok "the fake server was never called" || bad "calls in files mode: $(cat "$CALLS")"
reset; export SALA_INBOX_MODE=auto STACKSHOT_URL=http://127.0.0.1:1; mkdir -p "$SALA_INBOX_HOLD_DIR"; inbox_hold "$U1" "$N1"
[ ! -e "$CALLS" ] && grep -qxF "$U1" "$SALA_INBOX_HOLD_DIR/held-msg.txt" && ok "auto with a loopback URL: files, the server never asked" || bad "auto loopback"
reset; export STACKSHOT_URL=$REMOTE; inbox_hold "$U1" "$N1"
[ "$(lastcall)" = "post inbox-hold $U1 $N1 --minutes 10" ] && [ ! -e "$SALA_INBOX_HOLD_DIR" ] && ok "auto with another machine's URL: the server's call, no hold folder" || bad "auto remote: $(lastcall)"
unset STACKSHOT_URL

echo "== the fail-safe: a server that does not answer is no answer, never held and never nothing"
export SALA_INBOX_MODE=server
for how in down e500 e401 garbage partial; do
    reset; export FAKE_INBOX_FAIL=hold FAKE_INBOX_HOW=$how
    inbox_hold "$U1" "$N1" 2>"$T/err"; rc=$?
    [ "$rc" = 1 ] && [ -n "$INBOX_WHY" ] && grep -q 'was not made' "$T/err" && ok "$how: inbox_hold returns 1 and says why ($INBOX_WHY)" || bad "$how: rc=$rc why='$INBOX_WHY' err=$(cat "$T/err")"
    [ "$(rows)" = 1 ] && ok "$how: the ledger row stays, so the watch frees whatever the server did take" || bad "$how: ledger: $(cat "$LEDGER")"
done
reset; export FAKE_INBOX_FAIL=hold FAKE_INBOX_HOW=hang SALA_INBOX_TIMEOUT=1
SECONDS=0; inbox_hold "$U1" "$N1" 2>/dev/null; rc=$?
[ "$rc" = 1 ] && [ "$SECONDS" -le 5 ] && has "$INBOX_WHY" "did not answer within" && ok "a server that hangs is cut at SALA_INBOX_TIMEOUT: no answer in ${SECONDS}s" || bad "hang: rc=$rc ${SECONDS}s why=$INBOX_WHY"
export SALA_INBOX_TIMEOUT=2
reset; export FAKE_INBOX_FAIL=all FAKE_INBOX_HOW=down
inbox_touch "$U1" "$N1" 2>"$T/err"; rc=$?; [ "$rc" = 0 ] && grep -q 'not refreshed' "$T/err" && ok "a touch that was not answered returns 0 and says so (the hold runs out on its own)" || bad "touch down: rc=$rc $(cat "$T/err")"
reset; export FAKE_INBOX_FAIL=release FAKE_INBOX_HOW=down
inbox_hold "$U1" "$N1"; inbox_release "$U1" "$N1" 2>"$T/err"; rc=$?
[ "$rc" = 0 ] && [ "$(rows)" = 1 ] && grep -q 'not released' "$T/err" && [ "$(fkey "$U1")" = 2 ] && ok "a release that was not answered returns 0, keeps its ledger row (the watch asks again) and says so" || bad "release down: rc=$rc rows=$(rows) $(cat "$T/err")"
unset FAKE_INBOX_FAIL; awk -F'\t' -v t=$(( $(now) - 700 )) 'BEGIN {OFS = "\t"} {$1 = t; print}' "$LEDGER" > "$LEDGER.new" && mv -f "$LEDGER.new" "$LEDGER"; inbox_release_stale
[ "$(fkey "$U1")" = 0 ] && [ "$(rows)" = 0 ] && ok "inbox_release_stale, once the server answers, releases it from the row" || bad "stale after recovery: $(cat "$HOLDS") rows=$(rows)"
echo "-- the breaker: one no answer, then the shell does not ask again for a while"
reset; export FAKE_INBOX_FAIL=all FAKE_INBOX_HOW=down SALA_INBOX_BREAKER=30
inbox_hold "$U1" "$N1" 2>/dev/null; c1=$(ncalls); inbox_hold "$U2" "$N2" 2>/dev/null; rc=$?; c2=$(ncalls)
[ "$c1" = 1 ] && [ "$c2" = 1 ] && [ "$rc" = 1 ] && has "$INBOX_WHY" "a moment ago" && ok "the second call is answered by the breaker: no second call, still no answer (1)" || bad "breaker: calls $c1 $c2 rc=$rc why=$INBOX_WHY"
inbox_line_waiting "$N1" "$U1"; rc=$?; [ "$rc" = 0 ] && [ "$INBOX_WAIT_UNKNOWN" = 1 ] && [ "$(ncalls)" = 1 ] && ok "the waiting check under the breaker: a line waits (no answer), no call made" || bad "breaker waiting: rc=$rc unknown=$INBOX_WAIT_UNKNOWN"
export SALA_INBOX_BREAKER=0; _INBOX_DOWN=0; unset FAKE_INBOX_FAIL FAKE_INBOX_HOW; inbox_hold "$U1" "$N1" && ok "with the server back (and the breaker off) the hold is made" || bad "recovered hold"

echo "-- a 400 is the server's refusal (a bad key, kind or time, the 500-key cap), never a missing call: no fallback to the hold files"
reset; export FAKE_INBOX_FAIL=hold FAKE_INBOX_HOW=e400; mkdir -p "$SALA_INBOX_HOLD_DIR"
inbox_hold "$U1" "$N1" 2>"$T/err"; rc=$?
[ "$rc" = 1 ] && has "$INBOX_WHY" "answered 400" && [ ! -s "$SALA_INBOX_HOLD_DIR/held-msg.txt" ] && [ ! -s "$SALA_INBOX_HOLD_DIR/held-hub.txt" ] && ok "a 400 to the hold: no answer (1), and the keys did not go into the hold files" || bad "400: rc=$rc why=$INBOX_WHY files=$(cat "$SALA_INBOX_HOLD_DIR"/held-*.txt 2>/dev/null)"
reset; export FAKE_INBOX_CAP=1; mkdir -p "$SALA_INBOX_HOLD_DIR"
inbox_hold "$U1" "$N1" 2>"$T/err"; rc=$?
[ "$rc" = 1 ] && has "$INBOX_WHY" "at most 1 keys" && ok "a source whose API file is full (FAKE_INBOX_CAP=1): the server's 400 names the cap, the hold is not made (1)" || bad "cap: rc=$rc why=$INBOX_WHY"
unset FAKE_INBOX_CAP FAKE_INBOX_FAIL FAKE_INBOX_HOW
reset; n0=$(ncalls); helper hold 10 "--evil" "$U1" >"$T/out"; rc=$?
[ "$rc" = 2 ] && [ "$(ncalls)" = "$n0" ] && has "$(cat "$T/out")" "cannot carry" && ok "a key the calls would refuse (it starts with --) is no answer and no call is made" || bad "bad key: rc=$rc calls=$(ncalls) $(cat "$T/out")"
reset; K25=$(for i in $(seq 1 25); do printf 'k%02d ' "$i"; done); helper release $K25; rc=$?
[ "$rc" = 0 ] && [ "$(ncalls)" = 2 ] && ok "25 keys go out as two calls (the server takes 1 to 20 in one)" || bad "25 keys: rc=$rc calls=$(ncalls)"

echo "== the release names a key another tool still holds (held_elsewhere): left to it, no failure"
reset; export SALA_INBOX_MODE=server
fseed "$U1:file:-" "$N1:resume:-"
inbox_hold "$U1" "$N1"; inbox_release "$U1" "$N1" 2>"$T/err"; rc=$?
[ "$rc" = 0 ] && [ "$(fkey "$U1")" = 0 ] && [ "$(fkey "$N1")" = 0 ] && [ "$(forigin "$U1" file)" = 2 ] && [ "$(forigin "$N1" resume)" = 2 ] && ok "the API holds are lifted; the file hold and the reboot's resume hold are still there" || bad "elsewhere server: rc=$rc $(cat "$HOLDS")"
[ "$(rows)" = 0 ] && ok "sala's own hold is released, so its ledger row is dropped" || bad "elsewhere ledger: $(cat "$LEDGER")"
grep -q 'still held by another tool' "$T/err" && grep -q "$U1" "$T/err" && grep -q "$N1" "$T/err" && ok "it says which keys are still held, and that the tool that wrote them lifts them" || bad "elsewhere note: $(cat "$T/err")"
[ "${#INBOX_ELSEWHERE[@]}" = 2 ] && ok "INBOX_ELSEWHERE lists them" || bad "INBOX_ELSEWHERE: ${INBOX_ELSEWHERE[*]}"
r=$(helper release "$U1"); [ "$r" = "$(printf 'elsewhere\t%s' "$U1")" ] && ok "the helper prints the key as 'elsewhere TAB key' and exits 0" || bad "helper elsewhere: $r"
r=$(helper holds); has "$r" "$U1" && ! has "$r" "$N1" && ok "inbox-holds: the file row is listed (origin file); the resume row is never listed" || bad "holds list: $r"
reset; fseed "$U1:file:-"; inbox_release "$U1" "$N1" 2>"$T/err"; rc=$?
[ "$rc" = 0 ] && [ "$(forigin "$U1" file)" = 2 ] && ok "a key held only in another tool's file: the release is a 200 with nothing released, and the file hold stays" || bad "elsewhere only: rc=$rc"

echo "== exit code 4 (a delivery error a later try can get past): asked once more, then no answer that does not start the breaker"
reset; export FAKE_INBOX_FAIL=hold FAKE_INBOX_HOW=retry FAKE_INBOX_RETRY_TIMES=1 SALA_INBOX_BREAKER=30
inbox_hold "$U1" "$N1" 2>"$T/err"; rc=$?
[ "$rc" = 0 ] && [ "$(ncalls)" = 2 ] && [ "$(fkey "$U1")" = 2 ] && ok "one exit 4, then the answer: the hold is made, the call was repeated once (2 calls)" || bad "retry once: rc=$rc calls=$(ncalls) $(cat "$HOLDS" 2>/dev/null)"
reset; export FAKE_INBOX_FAIL=hold FAKE_INBOX_HOW=retry FAKE_INBOX_RETRY_TIMES=9
inbox_hold "$U1" "$N1" 2>"$T/err"; rc=$?; c1=$(ncalls)
[ "$rc" = 1 ] && [ "$c1" = 2 ] && has "$INBOX_WHY" "later try" && grep -q 'was not made' "$T/err" && ok "exit 4 twice: not made (1), asked twice and no more, the reason says a later try can" || bad "retry always: rc=$rc calls=$c1 why=$INBOX_WHY"
inbox_hold "$U1" "$N1" 2>/dev/null; [ "$(ncalls)" = 4 ] && [ "$_INBOX_DOWN" = 0 ] && ok "no breaker: the next hold asks the server again at once" || bad "breaker after exit 4: calls=$(ncalls) down=$_INBOX_DOWN"
inbox_touch "$U1" "$N1" 2>"$T/err"; rc=$?; [ "$rc" = 0 ] && grep -q 'not refreshed' "$T/err" && ok "a touch that got exit 4 returns 0 and says so" || bad "touch retry: rc=$rc $(cat "$T/err")"
export FAKE_INBOX_FAIL=release; inbox_release "$U1" "$N1" 2>"$T/err"; rc=$?; [ "$rc" = 0 ] && [ "$(rows)" -ge 1 ] && grep -q 'not released' "$T/err" && ok "a release that got exit 4 keeps its ledger row (the watch asks again)" || bad "release retry: rc=$rc rows=$(rows) $(cat "$T/err")"
rm -f "$FAKE_INBOX_DIR/retry.count"; export FAKE_INBOX_FAIL=waiting; inbox_line_waiting "$N1" "$U1"; rc=$?
[ "$rc" = 0 ] && [ "$INBOX_WAIT_UNKNOWN" = 1 ] && ok "the waiting check that got exit 4: a line waits (no answer), never nothing" || bad "waiting retry: rc=$rc unknown=$INBOX_WAIT_UNKNOWN"
export FAKE_INBOX_RETRY_TIMES=1; rm -f "$FAKE_INBOX_DIR/retry.count"; inbox_line_waiting "$N1" "$U1"; rc=$?
[ "$rc" = 1 ] && [ "$INBOX_WAIT_UNKNOWN" = 0 ] && ok "one exit 4 and then the answer: nothing waits, a real answer" || bad "waiting retry once: rc=$rc unknown=$INBOX_WAIT_UNKNOWN"
unset FAKE_INBOX_FAIL FAKE_INBOX_HOW FAKE_INBOX_RETRY_TIMES; export SALA_INBOX_BREAKER=0

echo "== a server without the call: the hold folder if this box has it, else no answer"
for how in e404 usage; do
    reset; export FAKE_INBOX_FAIL=all FAKE_INBOX_HOW=$how
    inbox_hold "$U1" "$N1" 2>/dev/null; rc=$?
    [ "$rc" = 1 ] && has "$INBOX_WHY" "no hold folder" && ok "$how, no hold folder here: no answer (1)" || bad "$how no folder: rc=$rc why=$INBOX_WHY"
    mkdir -p "$SALA_INBOX_HOLD_DIR"; inbox_hold "$U1" "$N1" 2>/dev/null; rc=$?
    [ "$rc" = 0 ] && grep -qxF "$U1" "$SALA_INBOX_HOLD_DIR/held-msg.txt" && grep -qxF "$N1" "$SALA_INBOX_HOLD_DIR/held-hub.txt" && ok "$how, with the hold folder: the keys went into the files" || bad "$how folder: rc=$rc"
    inbox_release "$U1" "$N1" 2>/dev/null; [ ! -s "$SALA_INBOX_HOLD_DIR/held-msg.txt" ] && [ "$(rows)" = 0 ] && ok "$how: the release took them out of the files again, and the ledger row with them" || bad "$how: release: $(cat "$SALA_INBOX_HOLD_DIR/held-msg.txt") rows=$(rows)"
done
reset; export FAKE_INBOX_FAIL=all FAKE_INBOX_HOW=e404; inbox_line_waiting "$N1" "$U1"; rc=$?
[ "$rc" = 0 ] && [ "$INBOX_WAIT_UNKNOWN" = 1 ] && has "$INBOX_WAIT_WHY" "no inbox folder" && ok "waiting check, server without the call, no inbox folder here: a line waits (no answer)" || bad "waiting 404: rc=$rc unknown=$INBOX_WAIT_UNKNOWN why=$INBOX_WAIT_WHY"
export SALA_STACKSHOT_INBOX="$T/inbox"; mkdir -p "$SALA_STACKSHOT_INBOX/hub" "$SALA_STACKSHOT_INBOX/msg"
inbox_line_waiting "$N1" "$U1"; rc=$?; [ "$rc" = 1 ] && [ "$INBOX_WAIT_UNKNOWN" = 0 ] && ok "with an inbox folder here, an empty one: nothing waits (a real answer)" || bad "waiting 404 folder: rc=$rc unknown=$INBOX_WAIT_UNKNOWN"
printf '{"to":"%s","text":"hello"}\n' "$N1" > "$SALA_STACKSHOT_INBOX/msg/a.json"; inbox_line_waiting "$N1" "$U1"; rc=$?
[ "$rc" = 0 ] && [ "$INBOX_WAIT_UNKNOWN" = 0 ] && [ "$INBOX_WAIT_KIND" = msg ] && ok "and a line in it waits, as the folder says" || bad "waiting 404 line: rc=$rc kind=$INBOX_WAIT_KIND"
unset SALA_STACKSHOT_INBOX

echo "== the waiting check: get inbox-waiting NAME,UUID, hub or msg, held or not"
reset; unset FAKE_INBOX_FAIL FAKE_INBOX_HOW; export SALA_INBOX_MODE=server
inbox_line_waiting "$N1" "$U1"; rc=$?
[ "$rc" = 1 ] && [ "$INBOX_WAIT_UNKNOWN" = 0 ] && [ -z "$INBOX_WAIT_KIND" ] && [ "$(lastcall)" = "get inbox-waiting $N1,$U1" ] && ok "an empty inbox: the server says nothing waits (1), by get inbox-waiting NAME,UUID" || bad "empty: rc=$rc call=$(lastcall)"
printf '{"id":"a","src":"hub","to":"%s","uuid":"","name":"%s","pid":"","text":"x","from":"x"}\n' "$N1" "$N1" > "$FAKE_INBOX_DIR/inbox/hub/a.json"
inbox_line_waiting "$N1" "$U1"; rc=$?; [ "$rc" = 0 ] && [ "$INBOX_WAIT_KIND" = hub ] && [ "$INBOX_WAIT_UNKNOWN" = 0 ] && ok "a hub line for the name: a line waits, kind hub" || bad "hub: rc=$rc kind=$INBOX_WAIT_KIND"
rm -f "$FAKE_INBOX_DIR/inbox/hub/a.json"
printf '{"id":"b","src":"msg","to":"other","uuid":"%s","name":"other","pid":"","text":"x","from":"x"}\n' "$U1" > "$FAKE_INBOX_DIR/inbox/msg/b.json"
inbox_line_waiting "$N1" "$U1"; rc=$?; [ "$rc" = 0 ] && [ "$INBOX_WAIT_KIND" = msg ] && ok "a msg line for the conversation id: a line waits, kind msg" || bad "msg: rc=$rc kind=$INBOX_WAIT_KIND"
inbox_hold "$U1" "$N1"; inbox_line_waiting "$N1" "$U1"; rc=$?; [ "$rc" = 0 ] && ok "held, the line still waits" || bad "held: rc=$rc"
rm -f "$FAKE_INBOX_DIR/inbox/msg/b.json"
printf '{"id":"c","src":"msg","to":"%s-extra","uuid":"","name":"%s-extra","pid":"","text":"mentions %s and %s","from":"x"}\n' "$N1" "$N1" "$N1" "$U1" > "$FAKE_INBOX_DIR/inbox/msg/c.json"
inbox_line_waiting "$N1" "$U1"; rc=$?; [ "$rc" = 1 ] && ok "a line for a longer name, or one that only mentions the session, waits for nobody here" || bad "extra: rc=$rc"
inbox_line_waiting "$N1" ""; [ "$(lastcall)" = "get inbox-waiting $N1" ] && ok "an empty uuid is left out of the key list" || bad "no uuid: $(lastcall)"
inbox_line_waiting "" ""; rc=$?; [ "$rc" = 1 ] && ok "no name and no uuid: nothing to ask (1)" || bad "no keys: rc=$rc"
for how in down e500 e401 garbage hang; do
    export FAKE_INBOX_FAIL=waiting FAKE_INBOX_HOW=$how SALA_INBOX_TIMEOUT=1
    inbox_line_waiting "$N1" "$U1"; rc=$?
    [ "$rc" = 0 ] && [ "$INBOX_WAIT_UNKNOWN" = 1 ] && [ -n "$INBOX_WAIT_WHY" ] && ok "$how: a line waits (0), flagged as unknown, why: $INBOX_WAIT_WHY" || bad "$how: rc=$rc unknown=$INBOX_WAIT_UNKNOWN"
done
export SALA_INBOX_TIMEOUT=2; unset FAKE_INBOX_FAIL FAKE_INBOX_HOW

echo "== the wake: a line wakes a sleeper; a server that cannot be asked wakes nobody"
reset; export SALA_SLEEP_DIR="$T/sleep" SALA_SIDECAR="$T/sidecar.tsv"; mkdir -p "$SALA_SLEEP_DIR"
printf '2026-11-23T00:00:00Z %s\n' "$N1" > "$SALA_SLEEP_DIR/$U1"; printf '%s\t%s\n' "$N1" "$U1" > "$SALA_SIDECAR"
r=$(wake_candidates); [ -z "$r" ] && ok "nothing waits: no candidate" || bad "candidates with no line: $r"
printf '{"id":"a","src":"hub","to":"%s","uuid":"","name":"%s","pid":"","text":"x","from":"x"}\n' "$N1" "$N1" > "$FAKE_INBOX_DIR/inbox/hub/a.json"
r=$(wake_candidates); [ "$r" = "$(printf '%s\t%s\t%s' "$N1" "$U1" hub)" ] && ok "a line waits on the server: the sleeper is a candidate, kind hub" || bad "candidates: $r"
export FAKE_INBOX_FAIL=waiting FAKE_INBOX_HOW=down
r=$(wake_candidates); [ -z "$r" ] && ok "the server cannot be reached: no candidate (no wake, so no failed wake to count)" || bad "candidates, server down: $r"
unset FAKE_INBOX_FAIL FAKE_INBOX_HOW

echo "== the orphans in server mode: an API hold with no time of its own and no ledger row, seen long enough"
reset; export SALA_INBOX_MODE=server; N=$(now)
fseed "APIKEY:api:-" "UNTIL:api:-" "OWNTIME:api:$((N + 300))" "RESUMEKEY:resume:-" "FILEKEY:file:-" "ACCOUNTED:api:-"
printf '%s\t%s\t%s\n' "$N" ACCOUNTED nobody >> "$LEDGER"
inbox_release_orphans
[ "${#INBOX_ORPHANS_FREED[@]}" = 0 ] && [ "$(fkey APIKEY)" = 2 ] && grep -qF APIKEY "$SEEN" && grep -qF UNTIL "$SEEN" && ! grep -qF OWNTIME "$SEEN" && ! grep -qF RESUMEKEY "$SEEN" && ! grep -qF FILEKEY "$SEEN" && ! grep -qF ACCOUNTED "$SEEN" && ok "first pass: the API holds with no time of their own are noted; a timed hold, a resume hold, another tool's file hold and an accounted key are not" || bad "first pass: freed=${INBOX_ORPHANS_FREED[*]} seen=$(cat "$SEEN" 2>/dev/null)"
[ "$(lastcall)" = "get inbox-holds" ] && ok "one call: get inbox-holds" || bad "call: $(lastcall)"
printf '%s\tAPIKEY\n%s\tUNTIL\n%s\tOWNTIME\n%s\tRESUMEKEY\n%s\tFILEKEY\n%s\tACCOUNTED\n' $((N - 700)) $((N - 30)) $((N - 700)) $((N - 700)) $((N - 700)) $((N - 700)) > "$SEEN"
inbox_release_orphans
[ "${INBOX_ORPHANS_FREED[*]}" = APIKEY ] && [ "$(lastcall)" = "post inbox-release APIKEY" ] && ok "seen 700 s: only APIKEY is freed, with one release call" || bad "second pass: freed=${INBOX_ORPHANS_FREED[*]} call=$(lastcall)"
[ "$(fkey APIKEY)" = 0 ] && [ "$(fkey UNTIL)" = 2 ] && [ "$(fkey OWNTIME)" = 2 ] && [ "$(forigin RESUMEKEY resume)" = 2 ] && [ "$(forigin FILEKEY file)" = 2 ] && [ "$(fkey ACCOUNTED)" = 2 ] && ok "on the server: the others are untouched, the resume hold and the other tool's file hold too" || bad "server after: $(cat "$HOLDS")"
! grep -qF APIKEY "$SEEN" && grep -qF UNTIL "$SEEN" && ok "the freed key is forgotten, the young one remembered" || bad "seen after: $(cat "$SEEN")"
echo "-- not answered: nothing freed, nothing forgotten"
fseed "APIKEY:api:-"; printf '%s\tAPIKEY\n' $((N - 700)) > "$SEEN"; export FAKE_INBOX_FAIL=holds FAKE_INBOX_HOW=down
inbox_release_orphans; [ "${#INBOX_ORPHANS_FREED[@]}" = 0 ] && [ "$(fkey APIKEY)" = 2 ] && grep -qF APIKEY "$SEEN" && ok "the list was not answered: nothing freed, the first-seen file as it was" || bad "holds down: freed=${INBOX_ORPHANS_FREED[*]} seen=$(cat "$SEEN")"
export FAKE_INBOX_FAIL=release; inbox_release_orphans
[ "${#INBOX_ORPHANS_FREED[@]}" = 0 ] && [ "$(fkey APIKEY)" = 2 ] && grep -q "^$((N - 700))	APIKEY" "$SEEN" && ok "the release was not answered: not reported freed, remembered with its first time" || bad "release down: freed=${INBOX_ORPHANS_FREED[*]} seen=$(cat "$SEEN")"
unset FAKE_INBOX_FAIL FAKE_INBOX_HOW; inbox_release_orphans
[ "${INBOX_ORPHANS_FREED[*]}" = APIKEY ] && [ "$(fkey APIKEY)" = 0 ] && ok "the next pass, with the server back, frees it" || bad "recovered: freed=${INBOX_ORPHANS_FREED[*]} $(cat "$HOLDS")"
echo "-- more than 20 keys: the release goes out in calls of at most 20"
specs=(); : > "$SEEN"; for i in $(seq 1 25); do specs+=("ORPH$i:api:-"); printf '%s\tORPH%s\n' $((N - 700)) "$i" >> "$SEEN"; done
fseed "${specs[@]}"; : > "$CALLS"; inbox_release_orphans
[ "${#INBOX_ORPHANS_FREED[@]}" = 25 ] && [ "$(lines "$CALLS")" = 3 ] && [ "$(fkey ORPH1)" = 0 ] && [ "$(fkey ORPH25)" = 0 ] && ok "25 orphans: the list, then two release calls, all freed" || bad "25 orphans: freed=${#INBOX_ORPHANS_FREED[@]} calls=$(lines "$CALLS")"
fseed "APIKEY:api:-"; export FAKE_INBOX_FAIL=all FAKE_INBOX_HOW=e404; printf '%s\tAPIKEY\n' $((N - 700)) > "$SEEN"; inbox_release_orphans
[ "${#INBOX_ORPHANS_FREED[@]}" = 0 ] && ok "an older server with no list and no hold folder here: nothing known, nothing freed" || bad "holds 404: ${INBOX_ORPHANS_FREED[*]}"
unset FAKE_INBOX_FAIL FAKE_INBOX_HOW

echo "== nothing left behind"
[ -z "$(ls "$SALA_INBOX_HOLD_DIR" 2>/dev/null | grep -v '^held-\(msg\|hub\)\.txt$')" ] && ok "no temporary file in the hold folder" || bad "left in the hold folder: $(ls "$SALA_INBOX_HOLD_DIR")"

[ "$fail" = 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
