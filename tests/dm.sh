#!/usr/bin/env bash
# tests/dm.sh — `sala dm` (lib/dm.sh): a message into a Slack app's Direct Message with the owner, as that app, with the app's bot token.
# The Slack API is a tiny local http server (python3, 127.0.0.1, a random port) that records each request and answers conversations.open,
# chat.postMessage and auth.test, with answers scripted per method from a queue file; nothing reaches the real Slack and no real token exists
# (the one here is made up). Everything runs in one temporary tree (locked while the suite runs, removed at its end); the server is stopped by
# its pid. A `curl` wrapper on PATH records every argument curl is given, so the suite can prove the token is never on a command line.
#   post       the happy path (open, then post, with thread_ts, the Bearer token and a JSON body), the channel cache (kept 600 in a 700 folder, reused
#              with no second open), a cached channel Slack rejects (channel_not_found, is_archived) dropped and opened again once, an uncached one not
#              retried, the thread ts as an argument or --thread=, the answer's ts as the only stdout; the cache is bound to the member id and the API
#              base (a changed SALA_DM_USER_ID or SALA_DM_API_BASE reopens the DM and posts to the new channel; an old file with a channel id alone,
#              or one with the wrong shape or a NUL byte, is ignored, never a crash); curl never reads ~/.curlrc (a `trace` line there writes no file)
#   message    stdin and argument forms arrive verbatim (backticks, $( ), quotes, newlines, a leading dash, non-ASCII) and run nothing; 39000
#              characters go, 39001 are refused (characters, not bytes) with nothing posted; empty, non-UTF-8, extra arguments refused
#   refusals   a bad, unlisted or unconfigured app name, a missing / empty / 644 / malformed token file, a missing or malformed SALA_DM_USER_ID,
#              each with its exit code and no request made
#   errors     Slack's error code is the only thing printed (and the token never is), 5xx retried once then network, a timeout, no server
#   token      --set-token refuses a non-terminal; dm_write_token (mode 600, atomic, no temp left, a new folder 700, an old one untouched); --check
#   set-token  the hidden prompt IS driven, through a pty (python3's pty module types a line at each prompt once the terminal's echo is off):
#              --set-token with no app (or --all) asks for every app in SALA_DM_APPS in turn: three stored from three lines (mode 600 each), an empty
#              line skips an app and keeps its old token, a bad value is refused for its app while the others store (exit 1), a write that fails
#              likewise, Ctrl-D skips the rest, an app listed twice is asked once, no value in any transcript or request; no terminal, no
#              SALA_DM_APPS, an unknown app and `--all <app>` are refused with exit 2; `--set-token <app>` is unchanged; tokens PASTED AHEAD
#              (typed a fixed gap apart, never waiting for a prompt, a slow `mv` holding sala between two prompts) are never echoed and the
#              terminal's echo flag is restored after the run and after a SIGTERM; an app name never starts with a dash (`--all` is never an app)
#   secrecy    the token in no process argument (the curl wrapper's record), in no output, state or cache file, over EVERY case: the per-case records
#              are deleted by reset, so an audit log (kept to the end) collects each case's curl arguments, outputs and state files first; a deliberate
#              leak was shown to fail it; lib/dm.sh names the token only where it builds curl's stdin config; the settings read from the config file
#              as from the environment
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
unset SALA_DM_APPS SALA_DM_USER_ID SALA_DM_TOKEN_DIR SALA_DM_API_BASE SALA_DM_TIMEOUT SALA_DM_RETRY_WAIT XDG_CONFIG_HOME CURL_HOME
mkdir -p "$HOME" "$T/tmp" "$T/ctl" "$T/bin"
CTL=$T/ctl; LOG=$CTL/log; ARGV=$T/curl-argv
AUDIT=$T/audit; mkdir -p "$AUDIT"   # survives reset(): every case's curl arguments, outputs and state files, for the secrecy check at the end
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
printf '#!/bin/bash\nprintf "%%s\\0" @@call@@ "$@" >> "%s"\nexec "%s" "$@"\n' "$ARGV" "$REAL_CURL" > "$T/bin/curl"; chmod +x "$T/bin/curl"
export PATH="$T/bin:$PATH"

# -- the settings every case shares -----------------------------------------------------------------------------------------------------------
export SALA_DM_APPS="alpha-app beta-app" SALA_DM_USER_ID=UTEST0001 SALA_DM_TOKEN_DIR=$T/tok SALA_DM_API_BASE="http://127.0.0.1:$PORT" SALA_DM_RETRY_WAIT=0
mkdir -p "$T/tok"; chmod 700 "$T/tok"
settoken() { rm -f "$T/tok/slack-bot-token-$1"; printf '%s\n' "${2:-$TOKEN}" > "$T/tok/slack-bot-token-$1"; chmod 600 "$T/tok/slack-bot-token-$1"; }   # <app> [token]
settoken alpha-app; settoken beta-app "$TOKEN"
# `sala dm` through a wrapper that keeps a copy of everything it printed (stdout and stderr) in the audit log, and hands both on unchanged
cat > "$T/bin/sala-dm" <<WRAP
#!/bin/bash
o=\$(mktemp "$T/tmp/out.XXXXXX"); e=\$(mktemp "$T/tmp/err.XXXXXX")
bash "$ROOT/bin/salamander" dm "\$@" >"\$o" 2>"\$e"; rc=\$?
cat "\$o" "\$e" >> "$AUDIT/output"; cat "\$o"; cat "\$e" >&2; rm -f "\$o" "\$e"; exit \$rc
WRAP
chmod +x "$T/bin/sala-dm"
S=$T/bin/sala-dm
CACHE=$SALA_STATE_DIR/dm/alpha-app.channel
nreq() { local n; n=$(grep -c "\"path\": \"/$1\"" "$LOG" 2>/dev/null); echo "${n:-0}"; }   # <method>: how many requests the fake saw
nall() { local n; n=$(grep -c . "$LOG" 2>/dev/null); echo "${n:-0}"; }
field() { python3 -I -c 'import json,sys; r=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]; i=int(sys.argv[2]); print(eval(sys.argv[3]))' "$LOG" "$1" "$2"; }   # <n> <expr over r[n-1]…>
last() { field "$(nall)" "r[i-1]$1"; }   # <subscript>: a field of the newest request
queue() { printf '%s\n' "$2" >> "$CTL/q.$1"; }   # <method> <"status json">
audit_collect() {   # append what the case just ended produced to the audit log (the raw text: the token is redacted only in the report)
    [ -f "$ARGV" ] && { cat "$ARGV"; printf '\0'; } >> "$AUDIT/argv"
    if [ -d "$SALA_STATE_DIR" ]; then
        find "$SALA_STATE_DIR" -type f -print -exec cat {} \; >> "$AUDIT/state" 2>/dev/null
        find "$SALA_STATE_DIR" -print >> "$AUDIT/state-list" 2>/dev/null
    fi
    return 0
}
reset() { audit_collect; : > "$LOG"; rm -f "$CTL"/q.* "$CTL/ts" "$ARGV"; rm -rf "$SALA_STATE_DIR/dm"; }
run() { OUT=$($S "$@" 2>"$T/err"); RC=$?; ERR=$(<"$T/err"); }   # <args…>: OUT, ERR, RC
CBASE=$SALA_DM_API_BASE
seedcache() { mkdir -p "$SALA_STATE_DIR/dm"; printf '%s\t%s\t%s\n' "$SALA_DM_USER_ID" "$CBASE" "$1" > "$CACHE"; }   # <channel>: a cache file for the current member and API
cached_channel() { local u b c; IFS=$'\t' read -r u b c < "$CACHE"; printf '%s' "$c"; }

# -- post: the happy path and the channel cache -----------------------------------------------------------------------------------------------
reset
run alpha-app --thread 1699999999.000100 'hello there'
[ "$RC" = 0 ] && [ "$OUT" = "1700000000.000001" ] && [ -z "$ERR" ] && ok "post: exit 0, stdout is the message's ts and nothing else, nothing on stderr" || bad "post: rc=$RC out=[$OUT] err=[$ERR]"
[ "$(nall)" = 2 ] && [ "$(field 1 'r[i-1]["path"]')" = /conversations.open ] && [ "$(field 2 'r[i-1]["path"]')" = /chat.postMessage ] && ok "post: conversations.open first, then chat.postMessage" || bad "post: requests: $(cat "$LOG")"
[ "$(field 1 'r[i-1]["body"]["users"]')" = UTEST0001 ] && ok "post: the DM is opened with SALA_DM_USER_ID" || bad "open body: $(field 1 'r[i-1]["body"]')"
[ "$(field 2 'r[i-1]["body"]["channel"]')" = D0TEST001 ] && [ "$(field 2 'r[i-1]["body"]["text"]')" = "hello there" ] && [ "$(field 2 'r[i-1]["body"]["thread_ts"]')" = 1699999999.000100 ] && ok "post: channel from the open, the text, and thread_ts" || bad "post body: $(field 2 'r[i-1]["body"]')"
[ "$(field 2 'r[i-1]["auth"]')" = "Bearer $TOKEN" ] && ok "post: the app's token goes in the Authorization header" || bad "auth header"
case "$(field 2 'r[i-1]["ctype"]')" in application/json*) ok "post: the body is JSON" ;; *) bad "content type: $(field 2 'r[i-1]["ctype"]')" ;; esac
[ "$(<"$CACHE")" = "$(printf 'UTEST0001\t%s\tD0TEST001' "$CBASE")" ] && [ "$(stat -c %a "$CACHE")" = 600 ] && [ "$(stat -c %a "$SALA_STATE_DIR/dm")" = 700 ] && ok "cache: the channel is kept per app with its member id and API base, file 600 in a folder 700" || bad "cache: [$(cat "$CACHE" 2>&1)] $(stat -c %a "$CACHE" "$SALA_STATE_DIR/dm" 2>&1 | tr '\n' ' ')"
ls -A "$SALA_STATE_DIR/dm" | grep -q '^\.' && bad "cache: a temporary file was left" || ok "cache: no temporary file left"
run alpha-app 'second'
[ "$RC" = 0 ] && [ "$(nreq conversations.open)" = 1 ] && [ "$(nreq chat.postMessage)" = 2 ] && [ "$(last '["body"]["channel"]')" = D0TEST001 ] && [ "$(last '["body"].get("thread_ts", "none")')" = none ] && ok "cache: the second post reuses the channel (no second conversations.open) and has no thread_ts" || bad "cache reuse: rc=$RC opens=$(nreq conversations.open)"
run beta-app 'other app'
[ "$RC" = 0 ] && [ "$(nreq conversations.open)" = 2 ] && [ -s "$SALA_STATE_DIR/dm/beta-app.channel" ] && ok "cache: each app has its own channel file" || bad "second app: rc=$RC opens=$(nreq conversations.open)"
run alpha-app --thread=1699999999.000200 'eq form'
[ "$RC" = 0 ] && [ "$(last '["body"]["thread_ts"]')" = 1699999999.000200 ] && ok "--thread=<ts> is the same as --thread <ts>" || bad "--thread= form: rc=$RC $ERR"

# a cached channel Slack no longer accepts is dropped and opened again, once
for code in channel_not_found is_archived; do
    reset; seedcache D0STALE01
    queue chat.postMessage "200 {\"ok\":false,\"error\":\"$code\"}"
    run alpha-app 'after a stale channel'
    [ "$RC" = 0 ] && [ "$OUT" = "1700000000.000001" ] && [ "$(nreq conversations.open)" = 1 ] && [ "$(nreq chat.postMessage)" = 2 ] && [ "$(cached_channel)" = D0TEST001 ] \
        && ok "stale cache ($code): dropped, the DM opened again, the post retried once, the new channel cached" || bad "stale cache $code: rc=$RC out=[$OUT] err=[$ERR] opens=$(nreq conversations.open) posts=$(nreq chat.postMessage)"
done
reset; seedcache D0STALE01
queue chat.postMessage '200 {"ok":false,"error":"channel_not_found"}'; queue chat.postMessage '200 {"ok":false,"error":"channel_not_found"}'
run alpha-app 'two rejections'
[ "$RC" = 1 ] && [ "$ERR" = "sala dm: slack error: channel_not_found" ] && [ "$(nreq conversations.open)" = 1 ] && [ "$(nreq chat.postMessage)" = 2 ] && ok "a channel Slack rejects after a fresh open is an error, not a loop (one re-open at most)" || bad "two rejections: rc=$RC err=[$ERR] opens=$(nreq conversations.open) posts=$(nreq chat.postMessage)"
reset; mkdir -p "$SALA_STATE_DIR/dm"; printf 'not a channel\n' > "$CACHE"
run alpha-app 'junk cache'
[ "$RC" = 0 ] && [ "$(nreq conversations.open)" = 1 ] && [ "$(cached_channel)" = D0TEST001 ] && ok "a cache file that holds no channel id is ignored and rewritten" || bad "junk cache: rc=$RC"

# the cache is bound to the member and the API base: changing either is no cache, with no clearing of state in between
reset
run alpha-app 'first'
[ "$RC" = 0 ] && [ "$(nreq conversations.open)" = 1 ] && [ "$(last '["body"]["channel"]')" = D0TEST001 ] || bad "bound cache: the first post: rc=$RC"
queue conversations.open '200 {"ok":true,"channel":{"id":"D0NEWUSR1"}}'
SALA_DM_USER_ID=UOTHER0002 run alpha-app 'for someone else'
[ "$RC" = 0 ] && [ "$(nreq conversations.open)" = 2 ] && [ "$(field 3 'r[i-1]["body"]["users"]')" = UOTHER0002 ] && [ "$(last '["body"]["channel"]')" = D0NEWUSR1 ] \
    && ok "cache: a changed SALA_DM_USER_ID opens the DM again for the new member and posts to its channel, not the previous recipient's" || bad "changed user: rc=$RC opens=$(nreq conversations.open) channel=$(last '["body"]["channel"]')"
SALA_DM_USER_ID=UOTHER0002 run alpha-app 'same new member'
[ "$RC" = 0 ] && [ "$(nreq conversations.open)" = 2 ] && [ "$(last '["body"]["channel"]')" = D0NEWUSR1 ] && ok "cache: the new member's channel is then cached (no third open)" || bad "new member cached: opens=$(nreq conversations.open)"
run alpha-app 'back to the first member'
[ "$RC" = 0 ] && [ "$(nreq conversations.open)" = 3 ] && [ "$(last '["body"]["channel"]')" = D0TEST001 ] && ok "cache: going back to the first member reopens too (one recipient per file, never a stale one)" || bad "back: opens=$(nreq conversations.open) channel=$(last '["body"]["channel"]')"
reset
run alpha-app 'first'
queue conversations.open '200 {"ok":true,"channel":{"id":"D0NEWAPI1"}}'
SALA_DM_API_BASE="http://localhost:$PORT" run alpha-app 'another api'
[ "$RC" = 0 ] && [ "$(nreq conversations.open)" = 2 ] && [ "$(last '["body"]["channel"]')" = D0NEWAPI1 ] && ok "cache: a changed SALA_DM_API_BASE opens the DM again and posts to the new channel" || bad "changed api base: rc=$RC err=[$ERR] opens=$(nreq conversations.open) channel=$(last '["body"]["channel"]')"
reset
run alpha-app 'first'
SALA_DM_API_BASE="$SALA_DM_API_BASE/" run alpha-app 'trailing slash'
[ "$RC" = 0 ] && [ "$(nreq conversations.open)" = 1 ] && ok "cache: a trailing slash on the API base is the same base (no reopen)" || bad "trailing slash: opens=$(nreq conversations.open)"
# an old cache file (a channel id alone) and other wrong shapes are ignored, never a crash, and rewritten in the new shape
for shape in 'D0STALE01' "UTEST0001	$CBASE" "UTEST0001	$CBASE	D0STALE01	extra" "UTEST0001	$CBASE	not-a-channel" "	$CBASE	D0STALE01"; do
    reset; mkdir -p "$SALA_STATE_DIR/dm"; printf '%s\n' "$shape" > "$CACHE"
    run alpha-app 'old cache'
    [ "$RC" = 0 ] && [ -z "$ERR" ] && [ "$(nreq conversations.open)" = 1 ] && [ "$(last '["body"]["channel"]')" = D0TEST001 ] && [ "$(cached_channel)" = D0TEST001 ] \
        && ok "cache: an old or malformed file ($(printf '%s' "$shape" | tr '\t' '|' | cut -c1-30)) is ignored safely and rewritten in the new shape" || bad "cache shape [$shape]: rc=$RC err=[$ERR] opens=$(nreq conversations.open)"
done
reset; mkdir -p "$SALA_STATE_DIR/dm"; : > "$CACHE"
run alpha-app 'empty cache file'; [ "$RC" = 0 ] && [ "$(nreq conversations.open)" = 1 ] && ok "cache: an empty file is ignored too" || bad "empty cache: rc=$RC"
# the first line is read strictly: exactly three tab-separated fields, none collapsed. `read` with IFS=tab takes a run of tabs for one separator, so
# the first four of these lines (doubled tabs, a trailing tab, an empty user id shifting the rest left) once parsed as a valid hit on D0STALE01
TB=$'\t'
for shape in "UTEST0001${TB}${TB}$CBASE${TB}D0STALE01" "UTEST0001${TB}$CBASE${TB}${TB}D0STALE01" "UTEST0001${TB}$CBASE${TB}D0STALE01${TB}" "${TB}UTEST0001${TB}$CBASE${TB}D0STALE01" "UTEST0001${TB}$CBASE${TB}D0STALE01${TB}extra" "${TB}$CBASE${TB}D0STALE01" "${TB}${TB}D0STALE01"; do
    reset; mkdir -p "$SALA_STATE_DIR/dm"; printf '%s\n' "$shape" > "$CACHE"
    run alpha-app 'strict cache'
    [ "$RC" = 0 ] && [ -z "$ERR" ] && [ "$(nreq conversations.open)" = 1 ] && [ "$(last '["body"]["channel"]')" = D0TEST001 ] && [ "$(cached_channel)" = D0TEST001 ] \
        && ok "cache: a line that is not exactly three tab-separated fields ($(printf '%s' "$shape" | sed 's/\t/<TAB>/g; s#http://127.0.0.1:[0-9]*#<base>#')) is no cache: the DM is opened again" \
        || bad "strict cache [$shape]: rc=$RC err=[$ERR] opens=$(nreq conversations.open) channel=$(last '["body"]["channel"]')"
done
# an empty user id field never matches, though SALA_DM_USER_ID is set
reset; mkdir -p "$SALA_STATE_DIR/dm"; printf '%s\t%s\t%s\n' "" "$CBASE" D0STALE01 > "$CACHE"
run alpha-app 'empty user id field'
[ "$RC" = 0 ] && [ "$(nreq conversations.open)" = 1 ] && [ "$(last '["body"]["channel"]')" = D0TEST001 ] && ok "cache: an empty user id field is no cache when SALA_DM_USER_ID is set" || bad "empty user id field: rc=$RC opens=$(nreq conversations.open)"
# the well-formed line is still a hit, with or without its newline; only the first line is read, so junk after it does not matter
reset; seedcache D0CACHED1
run alpha-app 'hit'
[ "$RC" = 0 ] && [ "$(nreq conversations.open)" = 0 ] && [ "$(last '["body"]["channel"]')" = D0CACHED1 ] && ok "cache: a well-formed line is a hit (no conversations.open)" || bad "well-formed hit: rc=$RC opens=$(nreq conversations.open) channel=$(last '["body"]["channel"]')"
reset; mkdir -p "$SALA_STATE_DIR/dm"; printf '%s\t%s\t%s' "$SALA_DM_USER_ID" "$CBASE" D0CACHED1 > "$CACHE"
run alpha-app 'hit, no newline'
[ "$RC" = 0 ] && [ "$(nreq conversations.open)" = 0 ] && [ "$(last '["body"]["channel"]')" = D0CACHED1 ] && ok "cache: a well-formed line with no final newline is a hit" || bad "no-newline hit: rc=$RC opens=$(nreq conversations.open)"
reset; seedcache D0CACHED1; printf 'junk\n\t\t\nUTEST0001\textra\n' >> "$CACHE"
run alpha-app 'hit, junk after'
[ "$RC" = 0 ] && [ "$(nreq conversations.open)" = 0 ] && [ "$(last '["body"]["channel"]')" = D0CACHED1 ] && ok "cache: a valid first line followed by junk lines is still a hit (only the first line is read)" || bad "junk after: rc=$RC opens=$(nreq conversations.open)"
reset; mkdir -p "$SALA_STATE_DIR/dm"; { printf 'junk\n'; printf '%s\t%s\t%s\n' "$SALA_DM_USER_ID" "$CBASE" D0CACHED1; } > "$CACHE"
run alpha-app 'junk before'
[ "$RC" = 0 ] && [ "$(nreq conversations.open)" = 1 ] && [ "$(last '["body"]["channel"]')" = D0TEST001 ] && ok "cache: a valid line that is not the first line is no cache" || bad "junk before: rc=$RC opens=$(nreq conversations.open)"
# bash `read` silently drops a NUL byte, so a NUL inside the channel id (D0ABC<NUL>JUNK), at the end of the line or in the user id field once read as a
# clean line and the DM went to the cached channel; a first line holding a NUL is no cache, whatever the rest looks like. A NUL on a later line is not the first line's.
for where in channel-id end-of-line user-id-field; do
    reset; mkdir -p "$SALA_STATE_DIR/dm"
    case "$where" in
        channel-id)     printf '%s\t%s\tD0STALE\0JUNK\n' "$SALA_DM_USER_ID" "$CBASE" > "$CACHE" ;;
        end-of-line)    printf '%s\t%s\tD0STALE01\0\n' "$SALA_DM_USER_ID" "$CBASE" > "$CACHE" ;;
        user-id-field)  printf '%s\0\t%s\tD0STALE01\n' "$SALA_DM_USER_ID" "$CBASE" > "$CACHE" ;;
    esac
    run alpha-app 'nul cache'
    [ "$RC" = 0 ] && [ -z "$ERR" ] && [ "$(nreq conversations.open)" = 1 ] && [ "$(last '["body"]["channel"]')" = D0TEST001 ] && [ "$(cached_channel)" = D0TEST001 ] \
        && ok "cache: a NUL byte in the first line ($where) is no cache: the DM is opened again, not posted to the cached channel" \
        || bad "NUL cache ($where): rc=$RC err=[$ERR] opens=$(nreq conversations.open) channel=$(last '["body"]["channel"]')"
done
reset; seedcache D0CACHED1; printf 'junk\0\n' >> "$CACHE"
run alpha-app 'hit, nul after'
[ "$RC" = 0 ] && [ "$(nreq conversations.open)" = 0 ] && [ "$(last '["body"]["channel"]')" = D0CACHED1 ] && ok "cache: a NUL on a later line does not matter (only the first line is read)" || bad "NUL after: rc=$RC opens=$(nreq conversations.open)"

# curl never reads the user's default config (~/.curlrc): a trace line there would record the token (the config on stdin) in a file
qfirst() { tr '\0' '\n' < "$1" | awk '/^@@call@@$/ { n++; getline a; if (a != "-q") bad++ } END { exit (n > 0 && !bad) ? 0 : 1 }'; }   # <argv record>: every curl call starts with -q
TRACE=$HOME/curl-trace.log
# curl looks for .curlrc in CURL_HOME first, then XDG_CONFIG_HOME, then HOME. The environment the suite runs in must not decide which: CURL_HOME is unset for
# the whole suite, and here it is set to the fixture HOME (the folder that holds the trace .curlrc) for each call only, the real runs and the control alike,
# so the control can only read the fixture's .curlrc, and so would the real runs if curl -q did not stop them
for opt in trace trace-ascii; do
    reset
    printf '%s = "%s"\n' "$opt" "$TRACE" > "$HOME/.curlrc"
    CURL_HOME=$HOME run alpha-app 'with a curlrc'
    [ "$RC" = 0 ] && [ -z "$ERR" ] && ok "curl ($opt in ~/.curlrc): a post still works" || bad "with curlrc ($opt): rc=$RC err=[$ERR]"
    [ ! -e "$TRACE" ] && ok "curl ($opt in ~/.curlrc): the trace file is never created (curl -q is its first argument)" || bad "curl read ~/.curlrc ($opt): the trace file exists"
    if grep -rqF -e "$TOKEN" -e "$TOKEN2" "$HOME" 2>/dev/null; then bad "a token was written to a file under HOME ($opt)"; else ok "curl ($opt in ~/.curlrc): the token is in no file under HOME"; fi
    qfirst "$ARGV" && ok "curl ($opt): -q is the first argument of the curl calls (the wrapper's record)" || bad "curl's first argument is not -q: [$(tr '\0' '\n' < "$ARGV" | sed -n 1,2p | tr '\n' ' ')]"
    # the check has teeth: without -q the real curl does read the same ~/.curlrc and writes the trace file (the token is in its stdin config)
    printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" | CURL_HOME=$HOME "$REAL_CURL" -sS -K - -X POST -o /dev/null "$SALA_DM_API_BASE/auth.test" >/dev/null 2>&1
    [ -s "$TRACE" ] && ok "curl ($opt): (control) without -q the same ~/.curlrc does create the trace file, so the checks above can fail" || bad "the ~/.curlrc control ($opt) produced no trace: the checks prove nothing"
    rm -f "$HOME/.curlrc" "$TRACE"
done

# an explicitly empty --thread is refused (2) in both forms, with no request made
reset
run alpha-app --thread '' 'x'
[ "$RC" = 2 ] && [ "$(nall)" = 0 ] && [ -z "$OUT" ] && case "$ERR" in *"--thread needs a message ts"*) true ;; *) false ;; esac && ok "--thread '' is a usage error (2), nothing posted" || bad "--thread '': rc=$RC err=[$ERR] requests=$(nall)"
run alpha-app --thread= 'x'
[ "$RC" = 2 ] && [ "$(nall)" = 0 ] && [ -z "$OUT" ] && case "$ERR" in *"--thread needs a message ts"*) true ;; *) false ;; esac && ok "--thread= (empty) is a usage error (2), nothing posted" || bad "--thread=: rc=$RC err=[$ERR] requests=$(nall)"
printf 'x' | $S alpha-app --thread '' - >/dev/null 2>&1; [ "$?" = 2 ] && [ "$(nall)" = 0 ] && ok "an empty --thread with the message on stdin is refused too" || bad "--thread '' with stdin"
# an empty value is refused where it is parsed: a later valid --thread must not overwrite it, an earlier one must not hide it
TS=1700000000.000100
reset; run alpha-app --thread '' --thread "$TS" 'x'
[ "$RC" = 2 ] && [ "$(nall)" = 0 ] && [ -z "$OUT" ] && case "$ERR" in *"--thread needs a message ts"*) true ;; *) false ;; esac && ok "--thread '' then a valid --thread: a usage error (2), nothing posted (the later flag does not overwrite the empty one)" || bad "--thread '' --thread ts: rc=$RC err=[$ERR] requests=$(nall)"
reset; run alpha-app --thread= --thread="$TS" 'x'
[ "$RC" = 2 ] && [ "$(nall)" = 0 ] && [ -z "$OUT" ] && case "$ERR" in *"--thread needs a message ts"*) true ;; *) false ;; esac && ok "--thread= then --thread=<ts>: a usage error (2), nothing posted" || bad "--thread= --thread=ts: rc=$RC err=[$ERR] requests=$(nall)"
reset; run alpha-app --thread "$TS" --thread '' 'x'
[ "$RC" = 2 ] && [ "$(nall)" = 0 ] && [ -z "$OUT" ] && case "$ERR" in *"--thread needs a message ts"*) true ;; *) false ;; esac && ok "a valid --thread then --thread '': a usage error (2), nothing posted" || bad "--thread ts --thread '': rc=$RC err=[$ERR] requests=$(nall)"
reset; run alpha-app --thread="$TS" --thread= 'x'
[ "$RC" = 2 ] && [ "$(nall)" = 0 ] && ok "a valid --thread=<ts> then --thread=: refused too" || bad "--thread=ts --thread=: rc=$RC err=[$ERR] requests=$(nall)"
reset; run alpha-app --thread "$TS" --thread 1700000000.000200 'x'
[ "$RC" = 0 ] && [ "$(last '["body"]["thread_ts"]')" = 1700000000.000200 ] && ok "two valid --thread flags: the later one wins (unchanged)" || bad "two valid threads: rc=$RC err=[$ERR] thread=$(last '["body"].get("thread_ts")')"
# a non-timestamp value is refused where it is parsed too: a later valid --thread must not overwrite it (it posted before), an earlier valid one must not hide it
reset; run alpha-app --thread bad --thread "$TS" 'x'
[ "$RC" = 2 ] && [ "$(nall)" = 0 ] && [ -z "$OUT" ] && case "$ERR" in *"--thread takes a message ts"*"'bad'"*) true ;; *) false ;; esac && ok "--thread bad then a valid --thread: a usage error (2), nothing posted (the later flag does not overwrite the bad one)" || bad "--thread bad --thread ts: rc=$RC err=[$ERR] requests=$(nall)"
reset; run alpha-app --thread=bad --thread="$TS" 'x'
[ "$RC" = 2 ] && [ "$(nall)" = 0 ] && [ -z "$OUT" ] && case "$ERR" in *"--thread takes a message ts"*"'bad'"*) true ;; *) false ;; esac && ok "--thread=bad then --thread=<ts>: a usage error (2), nothing posted" || bad "--thread=bad --thread=ts: rc=$RC err=[$ERR] requests=$(nall)"
reset; run alpha-app --thread "$TS" --thread bad 'x'
[ "$RC" = 2 ] && [ "$(nall)" = 0 ] && [ -z "$OUT" ] && case "$ERR" in *"--thread takes a message ts"*"'bad'"*) true ;; *) false ;; esac && ok "a valid --thread then --thread bad: a usage error (2), nothing posted" || bad "--thread ts --thread bad: rc=$RC err=[$ERR] requests=$(nall)"
reset; run alpha-app --thread="$TS" --thread=bad 'x'
[ "$RC" = 2 ] && [ "$(nall)" = 0 ] && ok "a valid --thread=<ts> then --thread=bad: refused too" || bad "--thread=ts --thread=bad: rc=$RC err=[$ERR] requests=$(nall)"
reset

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
# an app name never starts with a dash, even when it is listed in SALA_DM_APPS: `--all` (and any option-like name) cannot be an app, so
# `--set-token --all` can only mean every app (the old pattern allowed a leading dash, and a listed `--all` was then a valid app)
SALA_DM_APPS="--all -x alpha-app" run --all 'x'; [ "$RC" = 2 ] && [ "$(nall)" = 0 ] && case "$ERR" in *"does not start with a dash"*) true ;; *) false ;; esac && ok "a listed app named --all is refused as a name (2), nothing posted" || bad "app --all: rc=$RC err=[$ERR] requests=$(nall)"
SALA_DM_APPS="--all -x alpha-app" run -x 'x'; [ "$RC" = 2 ] && [ "$(nall)" = 0 ] && case "$ERR" in *"does not start with a dash"*) true ;; *) false ;; esac && ok "a listed app named -x is refused as a name (2), nothing posted" || bad "app -x: rc=$RC err=[$ERR] requests=$(nall)"
SALA_DM_APPS="--all -x alpha-app" run --check --all; [ "$RC" = 2 ] && [ "$(nall)" = 0 ] && case "$ERR" in *"does not start with a dash"*) true ;; *) false ;; esac && ok "--check --all: the same refusal (2), no request" || bad "check --all: rc=$RC err=[$ERR]"
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
settoken beta-app
# --set-token with no app (or --all) asks for every app in SALA_DM_APPS in turn. It needs a terminal, so the hidden prompt IS driven here: a pty
# (python3's pty module) runs `sala dm` with a terminal for stdin, stdout and stderr and types one line at each prompt, once the terminal's echo is off
# (so a typed value is never echoed into the transcript). The transcript (everything the owner would see) goes to the audit log too.
cat > "$T/pty-run.py" <<'PY'
import os, pty, select, signal, sys, termios, time
out, inp, mark = sys.argv[1], sys.argv[2], sys.argv[3].encode(); cmd = sys.argv[4:]
lines = open(inp).read().split("\n")[:-1]   # one typed line each; the literal <EOF> is Ctrl-D
pid, fd = pty.fork()
if pid == 0: os.execvp(cmd[0], cmd)
buf = b""; sent = 0; end = time.time() + 30; rc = None
while time.time() < end:
    if select.select([fd], [], [], 0.1)[0]:
        try: d = os.read(fd, 4096)
        except OSError: break
        if not d: break
        buf += d
    if sent < len(lines) and buf.count(mark) > sent:
        try: noecho = not (termios.tcgetattr(fd)[3] & termios.ECHO)
        except termios.error: noecho = False
        if noecho:
            os.write(fd, b"\x04" if lines[sent] == "<EOF>" else lines[sent].encode() + b"\n"); sent += 1
else:
    os.kill(pid, signal.SIGKILL); os.waitpid(pid, 0); open(out, "wb").write(buf); sys.exit(99)
_, st = os.waitpid(pid, 0)
open(out, "wb").write(buf.replace(b"\r", b""))
sys.exit(os.waitstatus_to_exitcode(st))
PY
TA=xoxb-test-all-alpha; TB=xoxb-test-all-beta; TC=xoxb-test-all-gamma; TOLD=xoxb-test-all-old; BADV=not-a-token-zzz9
ptyrun() { local mark=$1; shift; PTRC=; python3 -I "$T/pty-run.py" "$T/pty.out" "$T/pty.in" "$mark" bash "$ROOT/bin/salamander" dm "$@"; PTRC=$?; PTOUT=$(<"$T/pty.out"); cat "$T/pty.out" >> "$AUDIT/output"; }   # <prompt marker> <sala dm args…>: lines from $T/pty.in
feed() { printf '%s\n' "$@" > "$T/pty.in"; }   # the lines typed at the prompts, in order
tokmode() { stat -c %a "$T/tok/slack-bot-token-$1" 2>/dev/null; }
tokval() { head -n 1 "$T/tok/slack-bot-token-$1" 2>/dev/null; }
leaks() { grep -qF -e "$TA" -e "$TB" -e "$TC" -e "$TOLD" -e "$BADV" "$T/pty.out"; }   # 0 when a typed value (or a stored old one) is in the last transcript
M3='xoxb-...): '
SALA_DM_APPS="alpha-app beta-app gamma-app"; export SALA_DM_APPS
rm -rf "$T/tok"; mkdir -p "$T/tok"; chmod 700 "$T/tok"; reset
# all three stored in one run, from three typed lines
feed "$TA" "$TB" "$TC"; ptyrun "$M3" --set-token
[ "$PTRC" = 0 ] && [ "$(tokval alpha-app)" = "$TA" ] && [ "$(tokval beta-app)" = "$TB" ] && [ "$(tokval gamma-app)" = "$TC" ] && ok "--set-token (no app): three prompts, three tokens stored in one run, exit 0" || bad "set-token all: rc=$PTRC $(ls -A "$T/tok" | tr '\n' ' ')"
[ "$(tokmode alpha-app)" = 600 ] && [ "$(tokmode beta-app)" = 600 ] && [ "$(tokmode gamma-app)" = 600 ] && [ "$(stat -c %a "$T/tok")" = 700 ] && ! ls -A "$T/tok" | grep -q '^\.' && ok "--set-token (no app): each file is mode 600, no temporary file left" || bad "set-token all modes: $(stat -c '%n %a' "$T/tok"/* | tr '\n' ' ')"
[ "$(grep -c 'token for .* (Bot User OAuth Token, xoxb-\.\.\.): ' <<<"$PTOUT")" = 3 ] && grep -q 'token for alpha-app (Bot User OAuth Token, xoxb-...): ' <<<"$PTOUT" && ok "--set-token (no app): a prompt names each app's token, in SALA_DM_APPS order" || bad "set-token all prompts: [$PTOUT]"
o1=$(grep -n 'token for alpha-app (' <<<"$PTOUT" | head -1 | cut -d: -f1); o2=$(grep -n 'token for beta-app (' <<<"$PTOUT" | head -1 | cut -d: -f1); o3=$(grep -n 'token for gamma-app (' <<<"$PTOUT" | head -1 | cut -d: -f1)
[ -n "$o1" ] && [ "$o1" -lt "$o2" ] && [ "$o2" -lt "$o3" ] && ok "--set-token (no app): the apps are asked in the order SALA_DM_APPS lists them" || bad "set-token all order: $o1 $o2 $o3"
grep -q '^  alpha-app: stored$' <<<"$PTOUT" && grep -q '^  beta-app: stored$' <<<"$PTOUT" && grep -q '^  gamma-app: stored$' <<<"$PTOUT" && ok "--set-token (no app): the summary lists each app as stored" || bad "set-token all summary: [$PTOUT]"
leaks && bad "--set-token (no app): a typed value appears in the transcript" || ok "--set-token (no app): no typed value appears in the transcript (not echoed)"
[ "$(nall)" = 0 ] && ok "--set-token (no app): no request was made (nothing goes to the network)" || bad "set-token all made requests: $(nall)"
# --all is the same
rm -rf "$T/tok"; mkdir -p "$T/tok"; chmod 700 "$T/tok"
feed "$TA" "$TB" "$TC"; ptyrun "$M3" --set-token --all
[ "$PTRC" = 0 ] && [ "$(tokval alpha-app)" = "$TA" ] && [ "$(tokval beta-app)" = "$TB" ] && [ "$(tokval gamma-app)" = "$TC" ] && ok "--set-token --all is the same as --set-token with no app" || bad "set-token --all: rc=$PTRC"
# the single-app form is unchanged: one prompt, one token, the old output
rm -f "$T/tok/slack-bot-token-beta-app"
feed "$TB"; ptyrun 'then Enter: ' --set-token beta-app
[ "$PTRC" = 0 ] && [ "$(tokval beta-app)" = "$TB" ] && [ "$(tokmode beta-app)" = 600 ] && [ "$(grep -c 'Paste the bot token for' <<<"$PTOUT")" = 1 ] && grep -q '^stored token for beta-app$' <<<"$PTOUT" && ! grep -q 'summary' <<<"$PTOUT" && ok "--set-token <app> is unchanged: one prompt, stored, 'stored token for <app>', no summary" || bad "set-token single: rc=$PTRC [$PTOUT]"
feed "$BADV"; ptyrun 'then Enter: ' --set-token beta-app
[ "$PTRC" = 2 ] && [ "$(tokval beta-app)" = "$TB" ] && grep -q 'that is not a bot token (it must start with xoxb-); nothing stored' <<<"$PTOUT" && ok "--set-token <app> with a bad value: the same refusal (exit 2), the stored token untouched" || bad "set-token single bad: rc=$PTRC [$PTOUT]"
feed ""; ptyrun 'then Enter: ' --set-token beta-app
[ "$PTRC" = 2 ] && [ "$(tokval beta-app)" = "$TB" ] && ok "--set-token <app> with an empty line is still a refusal (2), not a skip" || bad "set-token single empty: rc=$PTRC"
# an empty line skips that app and keeps its old token
rm -rf "$T/tok"; mkdir -p "$T/tok"; chmod 700 "$T/tok"; settoken beta-app "$TOLD"
feed "$TA" "" "$TC"; ptyrun "$M3" --set-token
[ "$PTRC" = 0 ] && [ "$(tokval alpha-app)" = "$TA" ] && [ "$(tokval beta-app)" = "$TOLD" ] && [ "$(tokval gamma-app)" = "$TC" ] && ok "an empty line skips that app and keeps its old token; the others are stored; exit 0" || bad "skip: rc=$PTRC $(cat "$T/tok"/* | sed 's/.*/<tok>/' | tr '\n' ' ')"
grep -q '^skipped beta-app: nothing entered' <<<"$PTOUT" && grep -q '^  beta-app: skipped$' <<<"$PTOUT" && grep -q '^  alpha-app: stored$' <<<"$PTOUT" && grep -q '^  gamma-app: stored$' <<<"$PTOUT" && ok "a skipped app is said so, and the summary lists stored and skipped" || bad "skip summary: [$PTOUT]"
leaks && bad "skip: a typed value appears in the transcript" || ok "skip: no typed value appears in the transcript"
# an app with no token yet, skipped: nothing is created
rm -rf "$T/tok"; mkdir -p "$T/tok"; chmod 700 "$T/tok"
feed "" "$TB" ""; ptyrun "$M3" --set-token
[ "$PTRC" = 0 ] && [ ! -e "$T/tok/slack-bot-token-alpha-app" ] && [ ! -e "$T/tok/slack-bot-token-gamma-app" ] && [ "$(tokval beta-app)" = "$TB" ] && ok "a skipped app that had no token gets no file" || bad "skip empty app: rc=$PTRC $(ls -A "$T/tok")"
# a bad token is refused for that app, the others still store, the exit is 1
rm -rf "$T/tok"; mkdir -p "$T/tok"; chmod 700 "$T/tok"; settoken beta-app "$TOLD"
feed "$TA" "$BADV" "$TC"; ptyrun "$M3" --set-token
[ "$PTRC" = 1 ] && [ "$(tokval alpha-app)" = "$TA" ] && [ "$(tokval beta-app)" = "$TOLD" ] && [ "$(tokval gamma-app)" = "$TC" ] && ok "a bad token is refused for its app (old token kept), the other apps still store, exit 1" || bad "bad token: rc=$PTRC"
grep -q 'that is not a bot token (it must start with xoxb-); nothing stored' <<<"$PTOUT" && grep -q '^  beta-app: refused$' <<<"$PTOUT" && grep -q '^  alpha-app: stored$' <<<"$PTOUT" && grep -q '^  gamma-app: stored$' <<<"$PTOUT" && ok "the refusal is the single-app message, and the summary lists stored, refused, stored" || bad "bad token summary: [$PTOUT]"
leaks && bad "bad token: a typed value (the refused one included) appears in the transcript" || ok "bad token: neither the refused nor the stored values appear in the transcript"
# a bad first app does not stop the loop either, and a refused-only run is exit 1
rm -rf "$T/tok"; mkdir -p "$T/tok"; chmod 700 "$T/tok"
feed "$BADV" "$BADV" "$BADV"; ptyrun "$M3" --set-token
[ "$PTRC" = 1 ] && [ -z "$(ls -A "$T/tok")" ] && [ "$(grep -c 'nothing stored' <<<"$PTOUT")" = 3 ] && ok "three bad values: all three are asked and refused, nothing stored, exit 1" || bad "all bad: rc=$PTRC $(ls -A "$T/tok")"
# every app skipped is exit 0
feed "" "" ""; ptyrun "$M3" --set-token
[ "$PTRC" = 0 ] && [ -z "$(ls -A "$T/tok")" ] && ok "every app skipped: nothing stored, exit 0" || bad "all skipped: rc=$PTRC"
# a failed write for one app (its token path is a folder) is refused for that app, the others still store
rm -rf "$T/tok"; mkdir -p "$T/tok/slack-bot-token-beta-app"; chmod 700 "$T/tok"
feed "$TA" "$TB" "$TC"; ptyrun "$M3" --set-token
[ "$PTRC" = 1 ] && [ "$(tokval alpha-app)" = "$TA" ] && [ "$(tokval gamma-app)" = "$TC" ] && grep -q 'could not write' <<<"$PTOUT" && grep -q '^  beta-app: refused$' <<<"$PTOUT" && ok "a token file that cannot be written is refused for that app, the others store, exit 1" || bad "write failure: rc=$PTRC [$PTOUT]"
# Ctrl-D at a prompt skips that app and the rest, keeping what was stored
rm -rf "$T/tok"; mkdir -p "$T/tok"; chmod 700 "$T/tok"
feed "$TA" "<EOF>"; ptyrun "$M3" --set-token
[ "$PTRC" = 0 ] && [ "$(tokval alpha-app)" = "$TA" ] && [ ! -e "$T/tok/slack-bot-token-beta-app" ] && [ ! -e "$T/tok/slack-bot-token-gamma-app" ] && grep -q '^  beta-app: skipped$' <<<"$PTOUT" && grep -q '^  gamma-app: skipped$' <<<"$PTOUT" && ok "Ctrl-D skips the rest: the stored app stays, the others are listed as skipped, exit 0" || bad "ctrl-d: rc=$PTRC [$PTOUT]"
# a listed name twice is asked once; a lone app asks once
feed "$TA"; SALA_DM_APPS="alpha-app alpha-app" ptyrun "$M3" --set-token
[ "$PTRC" = 0 ] && [ "$(grep -c 'token for alpha-app (' <<<"$PTOUT")" = 1 ] && ok "an app listed twice in SALA_DM_APPS is asked once" || bad "duplicate app: rc=$PTRC [$PTOUT]"
# --set-token (no app) with `--all` listed as an app name: the name is refused as an app, so --all means every app and only the real apps are asked
rm -rf "$T/tok"; mkdir -p "$T/tok"; chmod 700 "$T/tok"
feed "$TA"; SALA_DM_APPS="--all alpha-app" ptyrun "$M3" --set-token --all
[ "$PTRC" = 1 ] && [ "$(tokval alpha-app)" = "$TA" ] && [ "$(grep -c 'token for .* (Bot User' <<<"$PTOUT")" = 1 ] && grep -q '^  --all: refused$' <<<"$PTOUT" && grep -q '^  alpha-app: stored$' <<<"$PTOUT" && ok "--set-token --all with an app named --all listed: that name is refused, never asked; the real app is" || bad "set-token --all named app: rc=$PTRC [$PTOUT]"
# tokens PASTED AHEAD must never be echoed. The owner can paste token 2 and 3 while sala is still working on token 1; `read -s` turns the
# terminal's echo off only while it is reading, so with echo back on between two reads that value was printed in clear. The check above waits
# for echo to be off before it types, which is why it could not see this. Here the driver types each line a fixed gap after the one before,
# without looking at the terminal, and a slow `mv` (first on PATH, a stand-in for the slow step between two prompts) holds sala in the gap
# where the old code had echo on. It also reads the terminal's echo flag after the run: the settings must be what they were before.
mkdir -p "$T/slowbin"; printf '#!/bin/bash\nsleep 0.5\nexec /usr/bin/mv "$@"\n' > "$T/slowbin/mv"; chmod +x "$T/slowbin/mv"
cat > "$T/pty-paste.py" <<'PY'
import os, pty, select, signal, sys, termios, time
out, inp, mark, gap, mode = sys.argv[1], sys.argv[2], sys.argv[3].encode(), float(sys.argv[4]), sys.argv[5]; cmd = sys.argv[6:]
lines = open(inp).read().split("\n")[:-1]   # one pasted line each, sent `gap` seconds apart whatever the terminal shows
pid, fd = pty.fork()
if pid == 0: os.execvp(cmd[0], cmd)
echo = lambda: bool(termios.tcgetattr(fd)[3] & termios.ECHO)
buf = b""; sent = 0; t0 = None; end = time.time() + 30; killed = False
while time.time() < end:
    if select.select([fd], [], [], 0.02)[0]:
        try: d = os.read(fd, 4096)
        except OSError: break
        if not d: break
        buf += d
    if t0 is None and buf.count(mark) >= 1 and not echo(): t0 = time.time()   # the first prompt is up and the terminal is quiet: start
    if t0 is not None:
        if mode == "term" and not killed: os.kill(pid, signal.SIGTERM); killed = True
        elif mode == "paste" and sent < len(lines) and time.time() >= t0 + sent * gap: os.write(fd, lines[sent].encode() + b"\n"); sent += 1
else:
    os.kill(pid, signal.SIGKILL); os.waitpid(pid, 0); open(out, "wb").write(buf); sys.exit(99)
_, st = os.waitpid(pid, 0)
open(out, "wb").write(buf.replace(b"\r", b""))
open(out + ".echo", "w").write("on" if echo() else "off")
sys.exit(os.waitstatus_to_exitcode(st))
PY
ptypaste() { local mode=$1 mark=$2; shift 2; PTRC=; PATH="$T/slowbin:$PATH" python3 -I "$T/pty-paste.py" "$T/pty.out" "$T/pty.in" "$mark" 0.25 "$mode" bash "$ROOT/bin/salamander" dm "$@"; PTRC=$?; PTOUT=$(<"$T/pty.out"); PTECHO=$(<"$T/pty.out.echo"); cat "$T/pty.out" >> "$AUDIT/output"; }   # <paste|term> <prompt marker> <sala dm args…>
TP1=xoxb-TEST-PASTE-1111; TP2=xoxb-TEST-PASTE-2222; TP3=xoxb-TEST-PASTE-3333
pleaks() { grep -qF -e "$TP1" -e "$TP2" -e "$TP3" "$T/pty.out"; }
rm -rf "$T/tok"; mkdir -p "$T/tok"; chmod 700 "$T/tok"; rm -f "$T/pty.out.echo"
feed "$TP1" "$TP2" "$TP3"; ptypaste paste "$M3" --set-token
[ "$PTRC" = 0 ] && [ "$(tokval alpha-app)" = "$TP1" ] && [ "$(tokval beta-app)" = "$TP2" ] && [ "$(tokval gamma-app)" = "$TP3" ] && ok "tokens pasted ahead (a quarter second apart, never waiting for a prompt): all three are stored, exit 0" || bad "paste ahead: rc=$PTRC $(ls -A "$T/tok" | tr '\n' ' ')"
pleaks && bad "tokens pasted ahead: a value was echoed into the terminal between two prompts" || ok "tokens pasted ahead: no value is ever echoed (the terminal's echo stays off between the prompts)"
[ "$PTECHO" = on ] && ok "after the run the terminal's echo is on again (the settings are put back)" || bad "echo after the paste run: $PTECHO"
# the single-app prompt: echo is back on after it, and a value pasted at it is not shown
rm -rf "$T/tok"; mkdir -p "$T/tok"; chmod 700 "$T/tok"; rm -f "$T/pty.out.echo"
feed "$TP2"; ptypaste paste 'then Enter: ' --set-token beta-app
[ "$PTRC" = 0 ] && [ "$(tokval beta-app)" = "$TP2" ] && ! pleaks && [ "$PTECHO" = on ] && ok "--set-token <app>: the value is not echoed and the terminal's echo is on again afterwards" || bad "single app echo: rc=$PTRC echo=$PTECHO"
# the settings are restored on a signal too: SIGTERM at the first prompt (echo off) leaves the terminal as it was, nothing stored
rm -rf "$T/tok"; mkdir -p "$T/tok"; chmod 700 "$T/tok"; rm -f "$T/pty.out.echo"
feed "$TP1"; ptypaste term "$M3" --set-token
[ "$PTRC" = 143 ] && [ "$PTECHO" = on ] && [ -z "$(ls -A "$T/tok")" ] && ok "SIGTERM at a prompt: the terminal's echo is restored, exit 143, nothing stored" || bad "sigterm: rc=$PTRC echo=$PTECHO $(ls -A "$T/tok")"
# refusals: a terminal is needed, the app list must exist, an unknown app is a usage error
rm -rf "$T/tok"; mkdir -p "$T/tok"; chmod 700 "$T/tok"
printf '%s\n%s\n%s\n' "$TA" "$TB" "$TC" | $S --set-token >"$T/o" 2>"$T/err"; rc=$?
[ "$rc" = 2 ] && grep -q 'needs a terminal' "$T/err" && [ -z "$(ls -A "$T/tok")" ] && ! grep -qF -e "$TA" -e "$TB" -e "$TC" "$T/o" "$T/err" && ok "--set-token (no app) with stdin a pipe: refused (2), nothing stored, no value echoed" || bad "set-token all pipe: rc=$rc $(cat "$T/err")"
$S --set-token --all </dev/null >"$T/o" 2>"$T/err"; rc=$?
[ "$rc" = 2 ] && grep -q 'needs a terminal' "$T/err" && [ -z "$(ls -A "$T/tok")" ] && ok "--set-token --all with stdin not a terminal: refused (2), nothing stored" || bad "set-token --all /dev/null: rc=$rc"
SALA_DM_APPS= $S --set-token </dev/null >"$T/o" 2>"$T/err"; rc=$?
[ "$rc" = 2 ] && [ "$(wc -l < "$T/err")" = 1 ] && grep -q 'SALA_DM_APPS' "$T/err" && ok "--set-token with no SALA_DM_APPS configured: a one-line usage error (2) naming the setting" || bad "set-token no apps: rc=$rc [$(cat "$T/err")]"
feed "$TA"; SALA_DM_APPS= ptyrun "$M3" --set-token
[ "$PTRC" = 2 ] && [ "$(wc -l <<<"$PTOUT")" = 1 ] && grep -q 'SALA_DM_APPS' <<<"$PTOUT" && ok "--set-token with no SALA_DM_APPS, even at a terminal: the same one-line usage error (2), no prompt" || bad "set-token no apps tty: rc=$PTRC [$PTOUT]"
$S --set-token gamma-app-x </dev/null >"$T/o" 2>"$T/err"; rc=$?
[ "$rc" = 2 ] && grep -q "unknown app 'gamma-app-x'" "$T/err" && ok "--set-token with an unknown app: usage error (2) naming it" || bad "set-token unknown: rc=$rc [$(cat "$T/err")]"
feed "$TA"; ptyrun "$M3" --set-token gamma-app-x
[ "$PTRC" = 2 ] && grep -q "unknown app 'gamma-app-x'" <<<"$PTOUT" && ! grep -q 'token for' <<<"$PTOUT" && ok "--set-token with an unknown app, at a terminal: exit 2, no prompt" || bad "set-token unknown tty: rc=$PTRC [$PTOUT]"
$S --set-token --all alpha-app </dev/null >/dev/null 2>"$T/err"; rc=$?
[ "$rc" = 2 ] && grep -q 'usage: sala dm --set-token' "$T/err" && ok "--set-token --all <app>: a usage error (2)" || bad "set-token --all app: rc=$rc [$(cat "$T/err")]"
export SALA_DM_APPS="alpha-app beta-app"
rm -rf "$T/tok"; mkdir -p "$T/tok"; chmod 700 "$T/tok"; settoken alpha-app; settoken beta-app "$TOKEN"; reset
reset
run --check alpha-app
[ "$RC" = 0 ] && [ "$OUT" = "ok: alpha-app is bot user U0BOT001 in team Test Team (T0TEST001)" ] && [ "$(field 1 'r[i-1]["path"]')" = /auth.test ] && [ "$(nall)" = 1 ] && ok "--check: auth.test with the token, prints the bot user id and the team" || bad "check: rc=$RC out=[$OUT] err=[$ERR]"
case "$OUT$ERR" in *xoxb*) bad "--check printed a token" ;; *) ok "--check prints no token" ;; esac
settoken alpha-app "$TOKEN2"; run --check alpha-app
[ "$RC" = 1 ] && [ "$ERR" = "sala dm: slack error: invalid_auth" ] && ok "--check with a token Slack refuses: exit 1 and the code" || bad "check bad token: rc=$RC err=[$ERR]"
settoken alpha-app; chmod 644 "$T/tok/slack-bot-token-alpha-app"; run --check alpha-app; [ "$RC" = 3 ] && ok "--check refuses a loose token file too" || bad "check 644: rc=$RC"
settoken alpha-app

# the settings come from the config file as well as from the environment
printf 'SALA_DM_APPS="alpha-app"\nSALA_DM_USER_ID=UFROMCFG1\nSALA_DM_TOKEN_DIR=%s\nSALA_DM_API_BASE=http://127.0.0.1:%s\n' "$T/tok" "$PORT" > "$T/config"
reset
( unset SALA_DM_APPS SALA_DM_USER_ID SALA_DM_TOKEN_DIR SALA_DM_API_BASE; SALA_CONFIG=$T/config $S alpha-app 'from the config' >/dev/null 2>&1 ); rc=$?
[ "$rc" = 0 ] && [ "$(field 1 'r[i-1]["body"]["users"]')" = UFROMCFG1 ] && ok "SALA_DM_APPS, _USER_ID, _TOKEN_DIR and _API_BASE read from the config file" || bad "config file settings: rc=$rc"
( unset SALA_DM_TOKEN_DIR; export XDG_CONFIG_HOME=$T/xdg; mkdir -p "$T/xdg/sala-briefing"; printf '%s\n' "$TOKEN" > "$T/xdg/sala-briefing/slack-bot-token-alpha-app"; chmod 600 "$T/xdg/sala-briefing/slack-bot-token-alpha-app"; $S alpha-app 'default dir' >/dev/null 2>&1 ); rc=$?
[ "$rc" = 0 ] && ok "without SALA_DM_TOKEN_DIR the token is read from \$XDG_CONFIG_HOME/sala-briefing" || bad "default token dir: rc=$rc"
grep -qF '${SALA_DM_API_BASE:-https://slack.com/api}' "$ROOT/lib/dm.sh" && ok "the API base defaults to https://slack.com/api (no suite calls it)" || bad "the default API base"

# -- secrecy -----------------------------------------------------------------------------------------------------------------------------------
# The per-case records (curl's argument log, the cache) are deleted by reset between cases, so these checks run over the AUDIT log: each case's
# curl arguments (NUL-separated), every output `sala dm` printed, and every file left under the state folder (path, then contents), collected
# before each reset and once more now, all at the end. The match is on the token string itself; a report shows counts and redacted lines only.
redact() { sed -e "s/$TOKEN/<TOKEN>/g" -e "s/$TOKEN2/<TOKEN2>/g" -e "s/$TA/<TA>/g" -e "s/$TB/<TB>/g" -e "s/$TC/<TC>/g" -e "s/$TOLD/<TOLD>/g" -e "s/$BADV/<BADV>/g" -e 's/xoxb-[A-Za-z0-9-]*/<xoxb>/g'; }
audit_collect
[ -s "$AUDIT/argv" ] && [ "$(tr -cd '\0' < "$AUDIT/argv" | wc -c)" -gt 100 ] && ok "(the audit log holds the curl arguments of every case: $(tr '\0' '\n' < "$AUDIT/argv" | grep -c '^@@call@@$') curl calls)" || bad "the audit log has no curl arguments"
[ -s "$AUDIT/state" ] && [ -s "$AUDIT/state-list" ] && [ -s "$AUDIT/output" ] && ok "(and the outputs and the state files of every case)" || bad "the audit log is missing outputs or state files"
qfirst "$AUDIT/argv" && ok "every curl call, over every case, started with -q (so ~/.curlrc is never read)" || bad "a curl call did not start with -q"
if grep -aqF -e "$TOKEN" -e "$TOKEN2" -e xoxb "$AUDIT/argv" 2>/dev/null; then bad "a token was in a curl argument list: $(tr '\0' '\n' < "$AUDIT/argv" | grep -aF -e "$TOKEN" -e "$TOKEN2" -e xoxb | redact | head -3 | tr '\n' '|')"; else ok "the token was in no curl argument list, over every case (the audit log, not the last case's record)"; fi
if grep -aqF -e "$TOKEN" -e "$TOKEN2" -e "$TA" -e "$TB" -e "$TC" -e "$TOLD" -e "$BADV" "$AUDIT/output" 2>/dev/null; then bad "a token was in the output of a call: $(grep -aF -e "$TOKEN" -e "$TOKEN2" -e "$TA" -e "$TB" -e "$TC" -e "$TOLD" -e "$BADV" "$AUDIT/output" | redact | head -3 | tr '\n' '|')"; else ok "the token was in no output (stdout or stderr) of any call, over every case"; fi
if grep -aqF -e "$TOKEN" -e "$TOKEN2" "$AUDIT/state" "$AUDIT/state-list" 2>/dev/null; then bad "a token was written under the state folder: $(grep -aF -e "$TOKEN" -e "$TOKEN2" "$AUDIT/state" "$AUDIT/state-list" | redact | head -3 | tr '\n' '|')"; else ok "the token is in no cache or state file, over every case"; fi
if grep -rqF -e "$TOKEN" -e "$TOKEN2" "$SALA_STATE_DIR" 2>/dev/null; then bad "a token was written under the state folder"; else ok "the token is in no cache or state file now"; fi
bad_lines=$(grep -nE '(^|[^A-Z_])DM_TOKEN([^A-Z_]|$)' "$ROOT/lib/dm.sh" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -vF -e 'DM_TOKEN=$tok' -e "printf 'header = \"Authorization: Bearer %s\"\\n' \"\$DM_TOKEN\" | curl" )
[ -z "$bad_lines" ] && ok "lib/dm.sh names the token variable only where it is read and where curl's stdin config is built" || bad "lib/dm.sh uses the token elsewhere: $bad_lines"
grep -nE 'curl[^|]*(-H|--header|-u|--user|--oauth2-bearer)[^|]*(DM_TOKEN|\$tok)' "$ROOT/lib/dm.sh" | grep -q . && bad "lib/dm.sh passes the token to curl as an argument" || ok "lib/dm.sh never hands the token to curl as an argument"

echo "dm: $([ $fail = 0 ] && echo pass || echo FAIL)"
exit $fail
