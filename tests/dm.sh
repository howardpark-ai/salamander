#!/usr/bin/env bash
# tests/dm.sh — `sala dm` (lib/dm.sh): a message into a Slack app's Direct Message with the owner, as that app, with the app's bot token.
# The Slack API is a tiny local http server (python3, 127.0.0.1, a random port) that records each request and answers conversations.open,
# chat.postMessage and auth.test, with answers scripted per method from a queue file; nothing reaches the real Slack and no real token exists
# (the one here is made up). Everything runs in one temporary tree (locked while the suite runs, removed at its end); the server is stopped by
# its pid. A `curl` wrapper on PATH records every argument curl is given, so the suite can prove the token is never on a command line.
#   post       the happy path (open, then post, with thread_ts, the Bearer token and a JSON body), the channel cache (kept 600 in a 700 folder, reused
#              with no second open), a cached channel Slack rejects (channel_not_found, is_archived) dropped and opened again once, an uncached one not
#              retried, the thread ts as an argument or --thread=, the answer's ts as the only stdout
#   message    stdin and argument forms arrive verbatim (backticks, $( ), quotes, newlines, a leading dash, non-ASCII) and run nothing; 39000
#              characters go, 39001 are refused (characters, not bytes) with nothing posted; empty, non-UTF-8, extra arguments refused
#   refusals   a bad, unlisted or unconfigured app name, a missing / empty / 644 / malformed token file, a missing or malformed SALA_DM_USER_ID,
#              each with its exit code and no request made
#   errors     Slack's error code is the only thing printed (and the token never is), 5xx retried once then network, a timeout, no server
#   token      --set-token refuses a non-terminal (the hidden prompt itself needs a terminal and is not driven here); dm_write_token (mode 600, atomic, no temp left, a new folder 700, an old one untouched); --check
#   secrecy    the token in no process argument (the curl wrapper's record), in no output, state or cache file; lib/dm.sh names it only where it
#              builds curl's stdin config; the settings read from the config file as from the environment
# Usage: bash tests/dm.sh   (exit 0 = pass; some ten seconds)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
. "$ROOT/tests/lib.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/sala-dm.XXXXXX")
exec 8< "$T"; flock -n 8 2>/dev/null   # systemd-tmpfiles' ageing skips a directory held with flock
SRV_PID=""
cleanup() { [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; exec 8<&-; rm -rf "$T"; }
trap cleanup EXIT
export HOME=$T/home SALA_CONFIG=/dev/null XDG_STATE_HOME=$T/state SALA_STATE_DIR=$T/state/salamander TMPDIR=$T/tmp
unset SALA_DM_APPS SALA_DM_USER_ID SALA_DM_TOKEN_DIR SALA_DM_API_BASE SALA_DM_TIMEOUT SALA_DM_RETRY_WAIT XDG_CONFIG_HOME
mkdir -p "$HOME" "$T/tmp" "$T/ctl" "$T/bin"
CTL=$T/ctl; LOG=$CTL/log; ARGV=$T/curl-argv
TOKEN=xoxb-test-secret-aaaa; TOKEN2=xoxb-test-secret-bbbb
printf '%s' "$TOKEN" > "$CTL/token"

# -- the fake Slack ---------------------------------------------------------------------------------------------------------------------------
cat > "$T/fake-slack.py" <<'PY'
import json, sys, time, http.server
ctl = sys.argv[1]
good = open(ctl + "/token").read().strip()
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        n = int(self.headers.get("content-length") or 0); raw = self.rfile.read(n)
        try: body = json.loads(raw.decode("utf-8"))
        except Exception: body = None
        method = self.path.lstrip("/")
        auth = self.headers.get("authorization", "")
        with open(ctl + "/log", "a") as f:
            f.write(json.dumps({"path": self.path, "auth": auth, "ctype": self.headers.get("content-type"), "body": body}) + "\n")
        status, out = 200, None
        try: lines = [l for l in open(ctl + "/q." + method).read().split("\n") if l]
        except OSError: lines = []
        if lines:   # a scripted answer: "<status> <json>", or "SLEEP <seconds>" (answers late)
            open(ctl + "/q." + method, "w").write("".join(l + "\n" for l in lines[1:]))
            head, _, rest = lines[0].partition(" ")
            if head == "SLEEP": time.sleep(float(rest)); out = {"ok": True, "ts": "1.0"}
            else: status = int(head); out = rest
        if out is None:
            if auth != "Bearer " + good: out = {"ok": False, "error": "invalid_auth"}
            elif method == "conversations.open": out = {"ok": True, "channel": {"id": "D0TEST001"}}
            elif method == "auth.test": out = {"ok": True, "user_id": "U0BOT001", "user": "testbot", "team": "Test Team", "team_id": "T0TEST001"}
            elif method == "chat.postMessage":
                try: k = int(open(ctl + "/ts").read())
                except OSError: k = 0
                open(ctl + "/ts", "w").write(str(k + 1))
                out = {"ok": True, "channel": body.get("channel") if body else None, "ts": "1700000000.%06d" % (k + 1)}
            else: out = {"ok": False, "error": "unknown_method"}
        data = (out if isinstance(out, str) else json.dumps(out)).encode()
        self.send_response(status); self.send_header("content-type", "application/json"); self.send_header("content-length", str(len(data))); self.end_headers()
        self.wfile.write(data)
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(ctl + "/port", "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
python3 -I "$T/fake-slack.py" "$CTL" &
SRV_PID=$!
waitfor '[ -s "$CTL/port" ]' 40 || { echo "  FAIL the fake Slack did not come up"; exit 1; }
PORT=$(<"$CTL/port")

# a curl that records its arguments (NUL-separated) and then runs the real one with the same arguments and stdin
REAL_CURL=$(command -v curl)
printf '#!/bin/bash\nprintf "%%s\\0" "$@" >> "%s"\nexec "%s" "$@"\n' "$ARGV" "$REAL_CURL" > "$T/bin/curl"; chmod +x "$T/bin/curl"
export PATH="$T/bin:$PATH"

# -- the settings every case shares -----------------------------------------------------------------------------------------------------------
export SALA_DM_APPS="alpha-app beta-app" SALA_DM_USER_ID=UTEST0001 SALA_DM_TOKEN_DIR=$T/tok SALA_DM_API_BASE="http://127.0.0.1:$PORT" SALA_DM_RETRY_WAIT=0
mkdir -p "$T/tok"; chmod 700 "$T/tok"
settoken() { rm -f "$T/tok/slack-bot-token-$1"; printf '%s\n' "${2:-$TOKEN}" > "$T/tok/slack-bot-token-$1"; chmod 600 "$T/tok/slack-bot-token-$1"; }   # <app> [token]
settoken alpha-app; settoken beta-app "$TOKEN"
S="bash $ROOT/bin/salamander dm"
CACHE=$SALA_STATE_DIR/dm/alpha-app.channel
nreq() { local n; n=$(grep -c "\"path\": \"/$1\"" "$LOG" 2>/dev/null); echo "${n:-0}"; }   # <method>: how many requests the fake saw
nall() { local n; n=$(grep -c . "$LOG" 2>/dev/null); echo "${n:-0}"; }
field() { python3 -I -c 'import json,sys; r=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]; i=int(sys.argv[2]); print(eval(sys.argv[3]))' "$LOG" "$1" "$2"; }   # <n> <expr over r[n-1]…>
last() { field "$(nall)" "r[i-1]$1"; }   # <subscript>: a field of the newest request
queue() { printf '%s\n' "$2" >> "$CTL/q.$1"; }   # <method> <"status json">
reset() { : > "$LOG"; rm -f "$CTL"/q.* "$CTL/ts" "$ARGV"; rm -rf "$SALA_STATE_DIR/dm"; }
run() { OUT=$($S "$@" 2>"$T/err"); RC=$?; ERR=$(<"$T/err"); }   # <args…>: OUT, ERR, RC

# -- post: the happy path and the channel cache -----------------------------------------------------------------------------------------------
reset
run alpha-app --thread 1699999999.000100 'hello there'
[ "$RC" = 0 ] && [ "$OUT" = "1700000000.000001" ] && [ -z "$ERR" ] && ok "post: exit 0, stdout is the message's ts and nothing else, nothing on stderr" || bad "post: rc=$RC out=[$OUT] err=[$ERR]"
[ "$(nall)" = 2 ] && [ "$(field 1 'r[i-1]["path"]')" = /conversations.open ] && [ "$(field 2 'r[i-1]["path"]')" = /chat.postMessage ] && ok "post: conversations.open first, then chat.postMessage" || bad "post: requests: $(cat "$LOG")"
[ "$(field 1 'r[i-1]["body"]["users"]')" = UTEST0001 ] && ok "post: the DM is opened with SALA_DM_USER_ID" || bad "open body: $(field 1 'r[i-1]["body"]')"
[ "$(field 2 'r[i-1]["body"]["channel"]')" = D0TEST001 ] && [ "$(field 2 'r[i-1]["body"]["text"]')" = "hello there" ] && [ "$(field 2 'r[i-1]["body"]["thread_ts"]')" = 1699999999.000100 ] && ok "post: channel from the open, the text, and thread_ts" || bad "post body: $(field 2 'r[i-1]["body"]')"
[ "$(field 2 'r[i-1]["auth"]')" = "Bearer $TOKEN" ] && ok "post: the app's token goes in the Authorization header" || bad "auth header"
case "$(field 2 'r[i-1]["ctype"]')" in application/json*) ok "post: the body is JSON" ;; *) bad "content type: $(field 2 'r[i-1]["ctype"]')" ;; esac
[ "$(<"$CACHE")" = D0TEST001 ] && [ "$(stat -c %a "$CACHE")" = 600 ] && [ "$(stat -c %a "$SALA_STATE_DIR/dm")" = 700 ] && ok "cache: the channel is kept per app, file 600 in a folder 700" || bad "cache: [$(cat "$CACHE" 2>&1)] $(stat -c %a "$CACHE" "$SALA_STATE_DIR/dm" 2>&1 | tr '\n' ' ')"
ls -A "$SALA_STATE_DIR/dm" | grep -q '^\.' && bad "cache: a temporary file was left" || ok "cache: no temporary file left"
run alpha-app 'second'
[ "$RC" = 0 ] && [ "$(nreq conversations.open)" = 1 ] && [ "$(nreq chat.postMessage)" = 2 ] && [ "$(last '["body"]["channel"]')" = D0TEST001 ] && [ "$(last '["body"].get("thread_ts", "none")')" = none ] && ok "cache: the second post reuses the channel (no second conversations.open) and has no thread_ts" || bad "cache reuse: rc=$RC opens=$(nreq conversations.open)"
run beta-app 'other app'
[ "$RC" = 0 ] && [ "$(nreq conversations.open)" = 2 ] && [ -s "$SALA_STATE_DIR/dm/beta-app.channel" ] && ok "cache: each app has its own channel file" || bad "second app: rc=$RC opens=$(nreq conversations.open)"
run alpha-app --thread=1699999999.000200 'eq form'
[ "$RC" = 0 ] && [ "$(last '["body"]["thread_ts"]')" = 1699999999.000200 ] && ok "--thread=<ts> is the same as --thread <ts>" || bad "--thread= form: rc=$RC $ERR"

# a cached channel Slack no longer accepts is dropped and opened again, once
for code in channel_not_found is_archived; do
    reset; mkdir -p "$SALA_STATE_DIR/dm"; printf 'D0STALE01\n' > "$CACHE"
    queue chat.postMessage "200 {\"ok\":false,\"error\":\"$code\"}"
    run alpha-app 'after a stale channel'
    [ "$RC" = 0 ] && [ "$OUT" = "1700000000.000001" ] && [ "$(nreq conversations.open)" = 1 ] && [ "$(nreq chat.postMessage)" = 2 ] && [ "$(<"$CACHE")" = D0TEST001 ] \
        && ok "stale cache ($code): dropped, the DM opened again, the post retried once, the new channel cached" || bad "stale cache $code: rc=$RC out=[$OUT] err=[$ERR] opens=$(nreq conversations.open) posts=$(nreq chat.postMessage)"
done
reset; mkdir -p "$SALA_STATE_DIR/dm"; printf 'D0STALE01\n' > "$CACHE"
queue chat.postMessage '200 {"ok":false,"error":"channel_not_found"}'; queue chat.postMessage '200 {"ok":false,"error":"channel_not_found"}'
run alpha-app 'two rejections'
[ "$RC" = 1 ] && [ "$ERR" = "sala dm: slack error: channel_not_found" ] && [ "$(nreq conversations.open)" = 1 ] && [ "$(nreq chat.postMessage)" = 2 ] && ok "a channel Slack rejects after a fresh open is an error, not a loop (one re-open at most)" || bad "two rejections: rc=$RC err=[$ERR] opens=$(nreq conversations.open) posts=$(nreq chat.postMessage)"
reset; mkdir -p "$SALA_STATE_DIR/dm"; printf 'not a channel\n' > "$CACHE"
run alpha-app 'junk cache'
[ "$RC" = 0 ] && [ "$(nreq conversations.open)" = 1 ] && [ "$(<"$CACHE")" = D0TEST001 ] && ok "a cache file that holds no channel id is ignored and rewritten" || bad "junk cache: rc=$RC"

# -- message: what arrives, and the length rule -----------------------------------------------------------------------------------------------
reset
EVIL='a `touch '"$T"'/pwned1` and $(touch '"$T"'/pwned2) and "quotes" and '"'"'single'"'"' and \n and \\ and $HOME and ${IFS} and é 日本 😀'$'\n''second line'
printf '%s\n' "$EVIL" | $S alpha-app - > "$T/o" 2>"$T/err"; rc=$?
[ "$rc" = 0 ] && [ "$(last '["body"]["text"]')" = "$EVIL" ] && ok "stdin (-): backticks, \$( ), quotes, backslashes, newlines and non-ASCII arrive verbatim" || bad "stdin form: rc=$rc got=[$(last '["body"]["text"]')]"
printf '%s' "$EVIL" | $S alpha-app > "$T/o" 2>"$T/err"; rc=$?
[ "$rc" = 0 ] && [ "$(last '["body"]["text"]')" = "$EVIL" ] && ok "stdin with no TEXT is the same" || bad "stdin, no TEXT: rc=$rc"
run alpha-app "$EVIL"
[ "$RC" = 0 ] && [ "$(last '["body"]["text"]')" = "$EVIL" ] && ok "an argument arrives verbatim too" || bad "argument form: rc=$RC"
[ ! -e "$T/pwned1" ] && [ ! -e "$T/pwned2" ] && ok "no text was run as a command" || bad "a command in the text ran"
run alpha-app -- '-starts with a dash'
[ "$RC" = 0 ] && [ "$(last '["body"]["text"]')" = "-starts with a dash" ] && ok "-- ends the options: a TEXT may start with a dash" || bad "dash text: rc=$RC err=[$ERR]"
printf 'trailing newlines go\n\n\n' | $S alpha-app - >/dev/null 2>&1; [ "$(last '["body"]["text"]')" = "trailing newlines go" ] && ok "trailing newlines are dropped, inner ones kept" || bad "trailing newlines: [$(last '["body"]["text"]')]"
reset
python3 -c 'print("x"*39000, end="")' | $S alpha-app - >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(last '["body"]["text"]' | wc -c)" -ge 39000 ] && ok "39000 characters are posted" || bad "39000: rc=$rc"
reset
python3 -c 'print("é"*39000, end="")' | $S alpha-app - >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "the limit counts characters, not bytes (39000 two-byte characters are posted)" || bad "39000 é: rc=$rc"
reset
OUT=$(python3 -c 'print("x"*39001, end="")' | $S alpha-app - 2>"$T/err"); RC=$?; ERR=$(<"$T/err")
[ "$RC" = 2 ] && [ "$(nall)" = 0 ] && case "$ERR" in *"over 39000 characters"*"nothing cut"*) true ;; *) false ;; esac && ok "39001 characters: refused with a clear error, nothing posted, nothing cut" || bad "39001: rc=$RC err=[$ERR] requests=$(nall)"
OUT=$(python3 -c 'import sys; sys.stdout.write("x"*500000)' 2>/dev/null | $S alpha-app - 2>"$T/err"); RC=$?; ERR=$(<"$T/err")
[ "$RC" = 2 ] && [ "$(nall)" = 0 ] && ok "a huge stdin is refused the same way" || bad "huge: rc=$RC err=[$ERR]"
run alpha-app ''; [ "$RC" = 2 ] && [ "$(nall)" = 0 ] && ok "an empty message is a usage error (2), nothing posted" || bad "empty: rc=$RC"
printf '  \n\n' | $S alpha-app - >/dev/null 2>&1; [ "$?" = 2 ] && [ "$(nall)" = 0 ] && ok "a message of blanks is refused too" || bad "blank message"
printf '\377\376bad' | $S alpha-app - >/dev/null 2>&1; [ "$?" = 2 ] && [ "$(nall)" = 0 ] && ok "a message that is not UTF-8 is refused, nothing posted" || bad "non-UTF-8"
run alpha-app one two; [ "$RC" = 2 ] && [ "$(nall)" = 0 ] && ok "two TEXT arguments are a usage error" || bad "two args: rc=$RC"
$S alpha-app </dev/null >/dev/null 2>&1; [ "$?" = 2 ] && [ "$(nall)" = 0 ] && ok "no TEXT and an empty stdin: usage error" || bad "empty stdin"
run alpha-app --thread abc 'x'; [ "$RC" = 2 ] && [ "$(nall)" = 0 ] && ok "a --thread that is not a ts is a usage error" || bad "bad thread: rc=$RC"
run alpha-app --thread; [ "$RC" = 2 ] && ok "--thread with no value is a usage error" || bad "--thread alone: rc=$RC"

# -- refusals: each with its exit code, and no request made -------------------------------------------------------------------------------------
reset
run 'bad_app!' 'x'; [ "$RC" = 2 ] && [ "$(nall)" = 0 ] && ok "an app name outside letters, digits and dashes: usage error (2)" || bad "bad name: rc=$RC"
run gamma-app 'x'; [ "$RC" = 2 ] && case "$ERR" in *"unknown app 'gamma-app'"*) true ;; *) false ;; esac && [ "$(nall)" = 0 ] && ok "an app not in SALA_DM_APPS: usage error, nothing posted" || bad "unlisted: rc=$RC err=[$ERR]"
run '' 'x'; [ "$RC" = 2 ] && ok "an empty app name: usage error" || bad "empty app: rc=$RC"
SALA_DM_APPS= run alpha-app 'x'; [ "$RC" = 3 ] && case "$ERR" in *SALA_DM_APPS*) true ;; *) false ;; esac && [ "$(nall)" = 0 ] && ok "no SALA_DM_APPS: setting problem (3) naming the variable" || bad "no apps: rc=$RC err=[$ERR]"
run; [ "$RC" = 2 ] && ok "no arguments: usage on stderr, exit 2" || bad "no args: rc=$RC"
run --help; [ "$RC" = 0 ] && case "$OUT" in "usage: sala dm"*) true ;; *) false ;; esac && ok "--help prints the usage, exit 0" || bad "--help: rc=$RC"
rm -f "$T/tok/slack-bot-token-alpha-app"
run alpha-app 'x'; [ "$RC" = 3 ] && case "$ERR" in *"no token file for alpha-app"*"missing"*) true ;; *) false ;; esac && [ "$(nall)" = 0 ] && ok "a missing token file: exit 3 and a message that says so, nothing posted" || bad "no token: rc=$RC err=[$ERR]"
: > "$T/tok/slack-bot-token-alpha-app"; chmod 600 "$T/tok/slack-bot-token-alpha-app"
run alpha-app 'x'; [ "$RC" = 3 ] && case "$ERR" in *empty*) true ;; *) false ;; esac && [ "$(nall)" = 0 ] && ok "an empty token file: exit 3" || bad "empty token: rc=$RC err=[$ERR]"
settoken alpha-app; chmod 644 "$T/tok/slack-bot-token-alpha-app"
run alpha-app 'x'; [ "$RC" = 3 ] && case "$ERR" in *"mode 644"*) true ;; *) false ;; esac && [ "$(nall)" = 0 ] && ok "a token file readable by group and other (644) is refused, nothing posted" || bad "mode 644: rc=$RC err=[$ERR]"
chmod 640 "$T/tok/slack-bot-token-alpha-app"; run alpha-app 'x'; [ "$RC" = 3 ] && ok "so is 640" || bad "mode 640: rc=$RC"
chmod 400 "$T/tok/slack-bot-token-alpha-app"; run alpha-app 'x'; [ "$RC" = 0 ] && ok "a stricter mode (400) is accepted" || bad "mode 400: rc=$RC err=[$ERR]"
settoken alpha-app 'not-a-bot-token'
run alpha-app 'x'; [ "$RC" = 3 ] && case "$ERR" in *"does not hold a bot token"*) true ;; *) false ;; esac && ! grep -q 'not-a-bot-token' <<<"$ERR$OUT" && ok "a value that is no bot token is refused without being printed" || bad "malformed token: rc=$RC err=[$ERR]"
settoken alpha-app; reset
SALA_DM_USER_ID= run alpha-app 'x'; [ "$RC" = 3 ] && case "$ERR" in *SALA_DM_USER_ID*) true ;; *) false ;; esac && [ "$(nall)" = 0 ] && ok "no SALA_DM_USER_ID: exit 3, the message names the variable, nothing posted" || bad "no user id: rc=$RC err=[$ERR]"
SALA_DM_USER_ID='x; touch y' run alpha-app 'x'; [ "$RC" = 3 ] && [ "$(nall)" = 0 ] && ok "a SALA_DM_USER_ID that is no member id is refused" || bad "bad user id: rc=$RC"

# -- Slack's answers, the network -------------------------------------------------------------------------------------------------------------
reset
queue chat.postMessage '200 {"ok":false,"error":"invalid_blocks"}'
run alpha-app 'x'
[ "$RC" = 1 ] && [ -z "$OUT" ] && [ "$ERR" = "sala dm: slack error: invalid_blocks" ] && ok "Slack ok:false: one line with Slack's error code, nothing on stdout, exit 1" || bad "slack error: rc=$RC out=[$OUT] err=[$ERR]"
reset
queue conversations.open '200 {"ok":false,"error":"missing_scope","needed":"im:write"}'
run alpha-app 'x'
[ "$RC" = 1 ] && [ "$ERR" = "sala dm: slack error: missing_scope" ] && [ "$(nreq chat.postMessage)" = 0 ] && [ ! -e "$CACHE" ] && ok "conversations.open refused: the same one line, nothing posted, nothing cached" || bad "open error: rc=$RC err=[$ERR]"
reset
queue chat.postMessage '200 {"ok":false,"error":"bad code with spaces <script>"}'
run alpha-app 'x'; [ "$RC" = 1 ] && [ "$ERR" = "sala dm: slack error: unknown_error" ] && ok "an error text that is no code is shown as unknown_error, never as Slack sent it" || bad "odd error: err=[$ERR]"
reset
settoken alpha-app "$TOKEN2"
run alpha-app 'x'
[ "$RC" = 1 ] && [ "$ERR" = "sala dm: slack error: invalid_auth" ] && ok "a token Slack does not know: invalid_auth, exit 1" || bad "invalid_auth: rc=$RC err=[$ERR]"
case "$OUT$ERR" in *"$TOKEN2"*|*"$TOKEN"*|*xoxb*) bad "a token appears in the output of a failed call" ;; *) ok "no token appears in the output of a failed call" ;; esac
settoken alpha-app
reset
queue chat.postMessage '503 {"ok":false}'
run alpha-app 'x'
[ "$RC" = 0 ] && [ "$(nreq chat.postMessage)" = 2 ] && ok "a 5xx is tried once more, and the post that follows is the result" || bad "5xx once: rc=$RC err=[$ERR] posts=$(nreq chat.postMessage)"
reset
queue chat.postMessage '503 {"ok":false}'; queue chat.postMessage '502 {"ok":false}'
run alpha-app 'x'
[ "$RC" = 4 ] && [ -z "$OUT" ] && [ "$(echo "$ERR" | wc -l)" = 1 ] && case "$ERR" in "sala dm: network: "*) true ;; *) false ;; esac && [ "$(nreq chat.postMessage)" = 2 ] && ok "a 5xx twice: one network line, exit 4, one retry only" || bad "5xx twice: rc=$RC err=[$ERR] posts=$(nreq chat.postMessage)"
reset
queue chat.postMessage 'SLEEP 4'; queue chat.postMessage 'SLEEP 4'
SALA_DM_TIMEOUT=1 run alpha-app 'x'
[ "$RC" = 4 ] && case "$ERR" in "sala dm: network: Slack did not answer within 1 s") true ;; *) false ;; esac && ok "a timeout: one line naming it, exit 4 (curl --max-time from SALA_DM_TIMEOUT)" || bad "timeout: rc=$RC err=[$ERR]"
reset
SALA_DM_API_BASE=http://127.0.0.1:1 run alpha-app 'x'
[ "$RC" = 4 ] && [ "$(echo "$ERR" | wc -l)" = 1 ] && case "$ERR" in "sala dm: network: could not reach Slack"*) true ;; *) false ;; esac && ok "no server: one line, exit 4" || bad "no server: rc=$RC err=[$ERR]"
reset
queue chat.postMessage '200 <html>not json</html>'
run alpha-app 'x'; [ "$RC" = 4 ] && case "$ERR" in *"not JSON"*) true ;; *) false ;; esac && ok "an answer that is not JSON: exit 4" || bad "not JSON: rc=$RC err=[$ERR]"
reset
queue chat.postMessage '200 {"ok":true}'
run alpha-app 'x'; [ "$RC" = 1 ] && [ -z "$OUT" ] && ok "ok:true with no message ts is an error (nothing to thread under)" || bad "no ts: rc=$RC out=[$OUT]"

# -- the token file writer, --set-token, --check ------------------------------------------------------------------------------------------------
wt() { SALA_ROOT="$ROOT" bash -c '. "$SALA_ROOT/lib/common.sh"; . "$SALA_ROOT/lib/dm.sh"; dm_write_token "$@"' _ "$@"; }
NEW=$T/newdir/tokens
SALA_DM_TOKEN_DIR=$NEW wt app-one "$TOKEN"; rc=$?
[ "$rc" = 0 ] && [ "$(<"$NEW/slack-bot-token-app-one")" = "$TOKEN" ] && [ "$(stat -c %a "$NEW/slack-bot-token-app-one")" = 600 ] && [ "$(stat -c %a "$NEW")" = 700 ] && ok "dm_write_token: the file holds the token, mode 600, a new folder 700" || bad "write: rc=$rc $(stat -c %a "$NEW" "$NEW"/* 2>&1 | tr '\n' ' ')"
ls -A "$NEW" | grep -q '^\.' && bad "dm_write_token left a temporary file" || ok "dm_write_token leaves no temporary file"
chmod 644 "$NEW/slack-bot-token-app-one"
SALA_DM_TOKEN_DIR=$NEW wt app-one "$TOKEN2"
[ "$(<"$NEW/slack-bot-token-app-one")" = "$TOKEN2" ] && [ "$(stat -c %a "$NEW/slack-bot-token-app-one")" = 600 ] && ok "dm_write_token replaces a token, and the mode is 600 again whatever it was" || bad "replace: $(stat -c %a "$NEW/slack-bot-token-app-one")"
mkdir -p "$T/olddir"; chmod 755 "$T/olddir"
SALA_DM_TOKEN_DIR=$T/olddir wt app-two "$TOKEN"
[ "$(stat -c %a "$T/olddir")" = 755 ] && [ "$(stat -c %a "$T/olddir/slack-bot-token-app-two")" = 600 ] && ok "an existing folder keeps its mode (other files live there); the token file is 600" || bad "old dir: $(stat -c %a "$T/olddir")"
# an interrupted write never leaves half a token: the old file stays when the move cannot happen (the target is a directory)
mkdir -p "$T/blockdir/slack-bot-token-app-three"
SALA_DM_TOKEN_DIR=$T/blockdir wt app-three "$TOKEN" 2>/dev/null; rc=$?
[ "$rc" != 0 ] && ! ls -A "$T/blockdir" | grep -q '^\.' && ok "a write that cannot finish fails and removes its temporary file" || bad "failed write: rc=$rc $(ls -A "$T/blockdir")"
reset
# --set-token needs a terminal: stdin from /dev/null or a pipe is refused, nothing is stored, the app is still checked first
rm -f "$T/tok/slack-bot-token-beta-app"
$S --set-token beta-app </dev/null >"$T/o" 2>"$T/err"; rc=$?
[ "$rc" = 2 ] && grep -q 'needs a terminal' "$T/err" && [ ! -e "$T/tok/slack-bot-token-beta-app" ] && ok "--set-token with stdin not a terminal: exit 2, nothing stored" || bad "set-token /dev/null: rc=$rc $(cat "$T/err")"
printf '%s\n' "$TOKEN" | $S --set-token beta-app >"$T/o" 2>"$T/err"; rc=$?
[ "$rc" = 2 ] && [ ! -e "$T/tok/slack-bot-token-beta-app" ] && ! grep -q "$TOKEN" "$T/o" "$T/err" && ok "--set-token from a pipe: refused too, and the value is not echoed" || bad "set-token pipe: rc=$rc"
$S --set-token gamma-app </dev/null >/dev/null 2>&1; [ "$?" = 2 ] && ok "--set-token for an unlisted app: usage error" || bad "set-token unlisted"
$S --set-token >/dev/null 2>&1; [ "$?" = 2 ] && ok "--set-token with no app: usage error" || bad "set-token no app"
settoken beta-app
reset
run --check alpha-app
[ "$RC" = 0 ] && [ "$OUT" = "ok: alpha-app is bot user U0BOT001 in team Test Team (T0TEST001)" ] && [ "$(field 1 'r[i-1]["path"]')" = /auth.test ] && [ "$(nall)" = 1 ] && ok "--check: auth.test with the token, prints the bot user id and the team" || bad "check: rc=$RC out=[$OUT] err=[$ERR]"
case "$OUT$ERR" in *xoxb*) bad "--check printed a token" ;; *) ok "--check prints no token" ;; esac
settoken alpha-app "$TOKEN2"; run --check alpha-app
[ "$RC" = 1 ] && [ "$ERR" = "sala dm: slack error: invalid_auth" ] && ok "--check with a token Slack refuses: exit 1 and the code" || bad "check bad token: rc=$RC err=[$ERR]"
settoken alpha-app; chmod 644 "$T/tok/slack-bot-token-alpha-app"; run --check alpha-app; [ "$RC" = 3 ] && ok "--check refuses a loose token file too" || bad "check 644: rc=$RC"
settoken alpha-app

# -- secrecy -----------------------------------------------------------------------------------------------------------------------------------
[ -s "$ARGV" ] && ok "(the curl wrapper recorded the run's arguments)" || bad "the curl wrapper recorded nothing"
if grep -qF -e "$TOKEN" -e "$TOKEN2" -e xoxb "$ARGV" 2>/dev/null; then bad "a token was in curl's argument list"; else ok "the token was in no curl argument list, over every case above"; fi
if grep -rqF -e "$TOKEN" -e "$TOKEN2" "$SALA_STATE_DIR" 2>/dev/null; then bad "a token was written under the state folder"; else ok "the token is in no cache or state file"; fi
bad_lines=$(grep -nE '(^|[^A-Z_])DM_TOKEN([^A-Z_]|$)' "$ROOT/lib/dm.sh" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -vF -e 'DM_TOKEN=$tok' -e "printf 'header = \"Authorization: Bearer %s\"\\n' \"\$DM_TOKEN\" | curl" )
[ -z "$bad_lines" ] && ok "lib/dm.sh names the token variable only where it is read and where curl's stdin config is built" || bad "lib/dm.sh uses the token elsewhere: $bad_lines"
grep -nE 'curl[^|]*(-H|--header|-u|--user|--oauth2-bearer)[^|]*(DM_TOKEN|\$tok)' "$ROOT/lib/dm.sh" | grep -q . && bad "lib/dm.sh passes the token to curl as an argument" || ok "lib/dm.sh never hands the token to curl as an argument"
# the settings come from the config file as well as from the environment
printf 'SALA_DM_APPS="alpha-app"\nSALA_DM_USER_ID=UFROMCFG1\nSALA_DM_TOKEN_DIR=%s\nSALA_DM_API_BASE=http://127.0.0.1:%s\n' "$T/tok" "$PORT" > "$T/config"
reset
( unset SALA_DM_APPS SALA_DM_USER_ID SALA_DM_TOKEN_DIR SALA_DM_API_BASE; SALA_CONFIG=$T/config bash "$ROOT/bin/salamander" dm alpha-app 'from the config' >/dev/null 2>&1 ); rc=$?
[ "$rc" = 0 ] && [ "$(field 1 'r[i-1]["body"]["users"]')" = UFROMCFG1 ] && ok "SALA_DM_APPS, _USER_ID, _TOKEN_DIR and _API_BASE read from the config file" || bad "config file settings: rc=$rc"
( unset SALA_DM_TOKEN_DIR; export XDG_CONFIG_HOME=$T/xdg; mkdir -p "$T/xdg/sala-briefing"; printf '%s\n' "$TOKEN" > "$T/xdg/sala-briefing/slack-bot-token-alpha-app"; chmod 600 "$T/xdg/sala-briefing/slack-bot-token-alpha-app"; bash "$ROOT/bin/salamander" dm alpha-app 'default dir' >/dev/null 2>&1 ); rc=$?
[ "$rc" = 0 ] && ok "without SALA_DM_TOKEN_DIR the token is read from \$XDG_CONFIG_HOME/sala-briefing" || bad "default token dir: rc=$rc"
grep -qF '${SALA_DM_API_BASE:-https://slack.com/api}' "$ROOT/lib/dm.sh" && ok "the API base defaults to https://slack.com/api (no suite calls it)" || bad "the default API base"

echo "dm: $([ $fail = 0 ] && echo pass || echo FAIL)"
exit $fail
