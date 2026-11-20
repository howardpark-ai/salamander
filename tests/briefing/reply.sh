#!/usr/bin/env bash
# reply.sh: a reply in a thread of the reports app's DM. The real reply.sh and post_slack run against a listener on 127.0.0.1
# playing the Slack API (chat.postMessage), the linker at no sessions, board or repos (links.sh tests those): thread_ts in the
# payload when given (else the reply lands outside its thread), the payload unchanged without it, a bad ts or an empty
# text refused before anything is posted, the text from stdin, exit 1 and no output when no app can deliver. Nothing leaves the
# box; the token is a made-up value in a temporary folder.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd); D=$ROOT/contrib/briefing
fail=0; ok() { echo "  ok   $*"; }; bad() { echo "  FAIL $*"; fail=1; }
T=$(mktemp -d); trap 'kill "${SRV:-}" 2>/dev/null; rm -rf "$T"' EXIT
# reply.sh posts to the reports channel: the caller's own sala config (a Slack app and its token) must never be read
mkdir -p "$T/home" "$T/logs" "$T/tok"; export HOME=$T/home SALA_CONFIG=$T/config; unset SALA_DM_TOKEN_DIR SALA_DM_API_BASE BRIEFING_CHANNEL SALA_NOTIFY_CHANNEL BRIEFING_THREAD_TS BRIEFING_NO_POST
export BRIEFING_LOGDIR=$T/logs BRIEFING_SESSIONS_CMD=true BRIEFING_BOARD_DIR=$T/no-board BRIEFING_COMMIT_REPOS=

python3 - "$T/port" "$T/body" <<'PY' &
import http.server, sys
port_file, body = sys.argv[1], sys.argv[2]
seen = [0]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        seen[0] += 1
        open(f"{body}.{seen[0]}", "wb").write(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        self.send_response(200); self.end_headers(); self.wfile.write(b'{"ok":true}')
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(port_file, "w").write(str(s.server_address[1]))
s.serve_forever()
PY
SRV=$!
for _ in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
[ -s "$T/port" ] || { bad "the 127.0.0.1 listener did not start"; exit 1; }
cat > "$T/config" <<EOF
BRIEFING_BOT_APP_REPORTS=rep-app
BRIEFING_BOT_CHANNEL_REPORTS=D0REPORTS
BRIEFING_BOT_APP_SALA_ADMIN=adm-app
BRIEFING_BOT_CHANNEL_SALA_ADMIN=D0ADMIN
EOF
for a in rep-app adm-app; do printf '%s\n' "fake-reply-test-token" > "$T/tok/slack-bot-token-$a"; chmod 600 "$T/tok/slack-bot-token-$a"; done
export SALA_DM_TOKEN_DIR=$T/tok SALA_DM_API_BASE=http://127.0.0.1:$(cat "$T/port")/api
posts() { ls "$T" | grep -c '^body\.' ; }
body() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8")); print(sorted(d)); print(d["channel"]); print(d.get("thread_ts", "-")); sys.stdout.write(d["text"])' "$T/body.$1" 2>/dev/null; }
TS=1760000000.123456

# thread_ts present: formatted like any post, with the ts added, to the reports app's DM
out=$("$D/reply.sh" "$TS" '**Done** in ~/x' 2>&1); rc=$?
[ $rc = 0 ] && [ "$out" = ok ] && ok "a reply prints Slack's answer" || bad "reply rc=$rc out=$out"
want=$(printf '%s\n%s\n%s\n%s' "['channel', 'text', 'thread_ts', 'unfurl_links', 'unfurl_media']" D0REPORTS "$TS" '*Done* in `~/x`')
[ "$(body 1)" = "$want" ] && ok "thread_ts in the payload, to the reports app's DM, the text through slack_text" || bad "reply payload: $(body 1)"

# thread_ts absent: post_slack's payload as before (no channel named: the sala-admin app's DM), also with BRIEFING_THREAD_TS set but empty
out=$(bash -c '. "$1" 2>/dev/null; post_slack "plain post"' _ "$D/lib.sh"); rc=$?
want=$(printf '%s\n%s\n%s\n%s' "['channel', 'text', 'unfurl_links', 'unfurl_media']" D0ADMIN - 'plain post')
[ $rc = 0 ] && [ "$out" = ok ] && [ "$(body 2)" = "$want" ] && ok "post_slack without a ts: payload unchanged" || bad "plain post rc=$rc out=$out: $(body 2)"
out=$(BRIEFING_THREAD_TS= bash -c '. "$1" 2>/dev/null; post_slack "plain post"' _ "$D/lib.sh")
[ "$(body 3)" = "$want" ] && ok "an empty BRIEFING_THREAD_TS adds no thread_ts" || bad "empty ts post: $(body 3)"

# a bad ts or an empty text: one line on stderr, non-zero, nothing posted
n=$(posts)
for bts in '' abc 1760000000 '1760000000.12a' ' 1760000000.123456'; do   # one per malformed shape (the rest dropped)
    err=$("$D/reply.sh" "$bts" 'hello' 2>&1 >/dev/null); rc=$?
    [ $rc != 0 ] && [ "$(printf '%s\n' "$err" | wc -l)" = 1 ] && [ -n "$err" ] && ok "bad ts '$bts' refused: $err" || bad "bad ts '$bts': rc=$rc err=$err"
done
err=$("$D/reply.sh" 2>&1 >/dev/null </dev/null); rc=$?
[ $rc != 0 ] && [ "$(printf '%s\n' "$err" | wc -l)" = 1 ] && ok "no arguments refused" || bad "no arguments: rc=$rc err=$err"
for case in arg-blank stdin-empty; do
    case $case in
        arg-blank) err=$("$D/reply.sh" "$TS" $' \n\t' 2>&1 >/dev/null </dev/null) ;;
        stdin-empty) err=$("$D/reply.sh" "$TS" 2>&1 >/dev/null </dev/null) ;;
    esac; rc=$?
    [ $rc != 0 ] && [ "$(printf '%s\n' "$err" | wc -l)" = 1 ] && ok "empty text refused ($case): $err" || bad "empty text ($case): rc=$rc err=$err"
done
[ "$(posts)" = "$n" ] && ok "nothing posted for a refused reply" || bad "a refused reply posted ($n -> $(posts))"

# the text from stdin when omitted; multi-line and non-ASCII kept
out=$(printf 'Zoë, done on line 1 — é\nline 2\n' | "$D/reply.sh" "$TS"); rc=$?
want=$(printf '%s\n%s\n%s\n%s' "['channel', 'text', 'thread_ts', 'unfurl_links', 'unfurl_media']" D0REPORTS "$TS" $'Zoë, done on line 1 — é\nline 2')
[ $rc = 0 ] && [ "$out" = ok ] && [ "$(body $((n+1)))" = "$want" ] && ok "text from stdin when omitted" || bad "stdin (omitted) rc=$rc out=$out: $(body $((n+1)))"

# through a symlink, from another directory (how a session may call it)
mkdir -p "$T/links" "$T/elsewhere"; ln -s "$D/reply.sh" "$T/links/reply.sh"
out=$(cd "$T/elsewhere" && "$T/links/reply.sh" "$TS" 'via a symlink'); rc=$?
[ $rc = 0 ] && [ "$out" = ok ] && ok "runs through a symlink from another directory" || bad "symlink rc=$rc out=$out"

# no app can deliver (the reports and sala-admin tokens gone): exit 1, nothing printed, no request, one log line per attempt
n=$(posts); rm -f "$T/tok/slack-bot-token-rep-app" "$T/tok/slack-bot-token-adm-app"
out=$("$D/reply.sh" "$TS" 'nobody home' 2>/dev/null); rc=$?
[ $rc = 1 ] && [ -z "$out" ] && [ "$(posts)" = "$n" ] && [ "$(grep -c 'reason=no_token_file' "$T/logs/bot-post.log")" = 2 ] \
    && ok "no token anywhere: exit 1, no output, nothing sent, one log line per app tried (the reports app, then sala-admin's)" || bad "undeliverable: rc=$rc out=[$out] posts $n -> $(posts) log=$(cat "$T/logs/bot-post.log" 2>/dev/null)"
exit $fail
