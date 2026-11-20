#!/usr/bin/env bash
# Posts through a channel's Slack app, and only so: post_slack delivers a post as the app's direct message (the app is the setting
# BRIEFING_BOT_APP_<NAME>, the DM is BRIEFING_BOT_CHANNEL_<NAME>, the token file is the one `sala dm` reads). There is no webhook: when no
# app can deliver, nothing is sent anywhere else, nothing is printed, the exit is non-zero and bot-post.log says why. One listener on
# 127.0.0.1 plays the Slack API (/api/...), recording each request's path, Authorization header and body; its answer is whatever the case
# puts in a file ($T/answer for every call, $T/seq/<k> for the k-th call of the case). Any request to another path (where a webhook would
# be) marks the run as failed. Checked:
#   - the token file present: chat.postMessage with the Bearer header, the channel (its name, or BRIEFING_BOT_CHANNEL_<NAME>), the text
#     and the two unfurl flags, no thread_ts; answer "ok"; no log line; SALA_NOTIFY_CHANNEL names the channel too
#   - BRIEFING_THREAD_TS set (a thread reply, reply.sh): the same app's chat.postMessage with that thread_ts (a reply in the thread of
#     its DM); a value that is not digits.digits is refused locally (bad_thread_ts); an empty value is no thread
#   - no app for the channel (a channel without a setting, no channel at all, a name outside [a-z0-9-]+): the sala-admin app's DM gets
#     the text under a first line `[post for channel <name> had no app mapped]` (a name outside the pattern shows as -); with the
#     sala-admin app unmapped nothing can deliver it: exit non-zero, no output, one log line (reason=no_app_mapped)
#   - a post that names no channel is the channel sala-admin: its app's DM, BRIEFING_BOT_CHANNEL_SALA_ADMIN (environment or config
#     lines); the mapping does not leak onto a named channel; a thread reply is a thread reply in that DM
#   - the order when an app fails: a remote failure is retried once (http_500, then ok: two API calls, no more); still failing, the
#     sala-admin app's DM gets the text under `[post for app <app> could not be delivered: <reason>]` (never in the thread: its parent
#     is in another DM); every DM failing: exit non-zero, no output, no webhook request, one log line per attempt; a local refusal
#     (token missing, mode 644) is not retried and goes straight to the sala-admin DM; sala-admin's own post is retried once and then
#     fails (no self-loop); sala-admin unmapped: the app twice, then failure
#   - token file missing / mode 644 / empty / a folder, an app name that is not a plain name, a bad channel setting: not delivered, one
#     log line (time, channel, app, reason); a loose-mode token is never sent anywhere
#   - Slack answers ok:false (its error code is logged and nothing else of the answer), HTTP 500 or 429, a redirect (never followed, so
#     the token goes nowhere else), an answer that is not JSON, a refused connection: two attempts, a log line each
#   - BRIEFING_NO_POST: nothing is sent; the text goes to would-post.log
#   - reply.sh: the thread reply is the reports app's chat.postMessage with its thread_ts; without the token it fails (exit 1, one log line)
#   - the settings from the sala config (SALA_DM_TOKEN_DIR, SALA_DM_API_BASE and the mapping), with the environment unset
#   - a copy of contrib/briefing alone (no lib/dm.sh beside it) still posts through the app
#   - the token is in no output, no log, no process's argument list or environment (sampled while a post is in flight)
# Fake values only ([masked Slack token], a temporary folder locked while the test runs, removed at the end); nothing leaves the box.
# Usage: bash tests/briefing/botpost.sh   (exit 0 = pass; a few seconds)
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd); D=$ROOT/contrib/briefing
fail=0; ok() { echo "  ok   $*"; }; bad() { echo "  FAIL $*"; fail=1; }
T=$(mktemp -d); trap 'kill "${SRV:-}" 2>/dev/null; rm -rf "$T"' EXIT
exec 8<"$T"; flock -n 8   # systemd-tmpfiles ageing honours a held flock on the folder
unset SALA_NOTIFY_CMD SALA_WATCH_NOTIFY_CMD SALA_STACKSHOT_WEB SALA_NOTIFY_CHANNEL BRIEFING_CHANNEL BRIEFING_THREAD_TS BRIEFING_NO_POST \
      BRIEFING_WEBHOOK_FILE BRIEFING_GMAIL_CONNECTOR BRIEFING_FORWARD_LABEL SALA_DM_TOKEN_DIR SALA_DM_API_BASE XDG_CONFIG_HOME \
      $(compgen -v | grep -E '^BRIEFING_(WEBHOOK_FILE|BOT_APP|BOT_CHANNEL)_')
mkdir -p "$T/home" "$T/blog" "$T/tok" "$T/req" "$T/seq"
export HOME=$T/home
TOKEN=xoxb-test-FAKE123

# the listener: /api/chat.postMessage answers from $T/answer (first line the HTTP status, the rest the body; none: 200 and ok:true),
# after a pause when $T/delay exists; /redir/chat.postMessage redirects to /api/chat.postMessage; any other path (where a webhook would be) answers ok and marks $T/hookhit
python3 - "$T/port" "$T/req" "$T/answer" "$T/delay" "$T/seq" <<'PY' &
import http.server, os, sys, time
port_file, base, answer, delay, seqdir = sys.argv[1:6]
seen = [0]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        seen[0] += 1; n = seen[0]
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        open(f"{base}/{n}.path", "w").write(self.path)
        open(f"{base}/{n}.auth", "w").write(self.headers.get("Authorization", "-"))
        open(f"{base}/{n}.body", "wb").write(body)
        if self.path == "/redir/chat.postMessage":
            self.send_response(302); self.send_header("Location", "/api/chat.postMessage"); self.end_headers(); return
        status, out = 200, b"ok"
        if not self.path.startswith(("/api/", "/redir/")):   # a webhook path: nothing may ask for one, the run fails at the end
            open(os.path.join(os.path.dirname(base), "hookhit"), "w").write(self.path)
        if self.path == "/api/chat.postMessage":
            if os.path.exists(delay): time.sleep(1.5)
            status, out = 200, b'{"ok":true,"ts":"1760000000.000100"}'
            # the k-th API request since the case began (the request files are cleared per case) answers from seq/k when that exists
            k = sum(1 for f in os.listdir(base) if f.endswith(".path") and open(f"{base}/{f}").read().startswith("/api/"))
            src = f"{seqdir}/{k}" if os.path.exists(f"{seqdir}/{k}") else answer
            if os.path.exists(src):
                head, _, rest = open(src, "rb").read().partition(b"\n")
                status, out = int(head), rest
        self.send_response(status); self.end_headers(); self.wfile.write(out)
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(port_file, "w").write(str(s.server_address[1]))
s.serve_forever()
PY
SRV=$!
for _ in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
[ -s "$T/port" ] || { bad "the 127.0.0.1 listener did not start"; exit 1; }
PORT=$(cat "$T/port")
API=http://127.0.0.1:$PORT/api

cat > "$T/config" <<EOF
BRIEFING_BOT_APP_REPORTS=demo-app
BRIEFING_BOT_APP_STACK_OPS=ops-app
BRIEFING_BOT_CHANNEL_STACK_OPS=C0FAKE123
BRIEFING_BOT_APP_BADAPP=../escape
BRIEFING_BOT_APP_BADCH=demo-app
BRIEFING_BOT_CHANNEL_BADCH="bad channel"
EOF
export SALA_CONFIG=$T/config SALA_DM_TOKEN_DIR=$T/tok SALA_DM_API_BASE=$API BRIEFING_LOGDIR=$T/blog \
       BRIEFING_SESSIONS_CMD=true BRIEFING_BOARD_DIR=$T/no-board BRIEFING_COMMIT_REPOS=

mk_token() { # mk_token <app> <mode> [content]: a token file with that mode ("" content: an empty file)
    local f=$T/tok/slack-bot-token-$1; rm -rf "$f"; printf '%s' "${3-}" > "$f"; chmod "$2" "$f"
}
mk_token demo-app 600 "$TOKEN"$'\n'; mk_token ops-app 600 "$TOKEN"$'\n'
fresh() { rm -f "$T"/req/* "$T"/seq/* "$T/answer" "$T/delay" "$T/blog/bot-post.log" "$T/blog/would-post.log"; }
nreq() { ls "$T/req" | grep -c '\.path$'; }
napi() { local n=0 f; for f in "$T"/req/*.path; do [ -e "$f" ] || continue; case $(cat "$f") in /api/*|/redir/*) n=$((n + 1));; esac; done; echo "$n"; }
nhook() { local n=0 f; for f in "$T"/req/*.path; do [ -e "$f" ] || continue; case $(cat "$f") in /hook*) n=$((n + 1));; esac; done; echo "$n"; }
# the first request to the API / the last to a webhook, as n (the file number)
apireq() { local f; for f in $(ls "$T/req" | grep '\.path$' | sort -n); do case $(cat "$T/req/$f") in /api/*) echo "${f%.path}"; return;; esac; done; }
hookreq() { local f r=""; for f in $(ls "$T/req" | grep '\.path$' | sort -n); do case $(cat "$T/req/$f") in /hook*) r=${f%.path};; esac; done; echo "$r"; }
body_eq() { python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])) == json.loads(sys.argv[2]) else 1)' "$1" "$2"; }
text_of() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["text"])' "$1"; }
logline() { cat "$T/blog/bot-post.log" 2>/dev/null; }
: > "$T/all.out"
# post <VAR=val…> -- <text>: the real lib.sh's post_slack with a clean channel environment; its output is $OUT (and kept in all.out)
post() {
    local envs=(); while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
    LAST=$1
    OUT=$(env -u BRIEFING_CHANNEL -u SALA_NOTIFY_CHANNEL -u BRIEFING_THREAD_TS ${envs[@]+"${envs[@]}"} \
        bash -c '. "$1/lib.sh" 2>/dev/null; post_slack "$2"' _ "${LIBDIR:-$D}" "$1" 2>&1); RC=$?
    printf '%s\n' "$OUT" >> "$T/all.out"
}
# undelivered <label> <reason> [channel app [attempts]]: no app could post: nothing on stdout, a non-zero exit, no request to a webhook path,
# and one bot-post.log line per failed attempt, each with the reason (a remote failure is tried twice, a local refusal once)
undelivered() {
    local label=$1 reason=$2 ch=${3:-reports} app=${4:-demo-app} n=${5:-1}
    if [ "$RC" != 0 ] && [ -z "$OUT" ] && [ "$(nhook)" = 0 ] && [ "$(logline | wc -l)" = "$n" ] \
       && [ "$(logline | grep -Ec "^[0-9-]{10} [0-9:]{8} channel=$ch app=$app reason=$reason\$")" = "$n" ]; then
        ok "$label: not delivered (exit $RC, no output, no webhook request); bot-post.log: $n x $(logline | head -1 | cut -d' ' -f3-)"
    else bad "$label: rc=$RC out=[$OUT] hooks=$(nhook) apis=$(napi) log=[$(logline)]"; fi
}
# apin <i>: the file number of the i-th request to the API; apfield <i> <field>: that request's channel or text
apin() { ls "$T/req" | grep '\.path$' | sort -n | while read -r f; do case $(cat "$T/req/$f") in /api/*) echo "${f%.path}";; esac; done | sed -n "${1}p"; }
apfield() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$T/req/$(apin "$1").body" "$2"; }
seq_answer() { printf '%s\n%s' "$2" "$3" > "$T/seq/$1"; }   # seq_answer <k> <status> <body>: the answer to the k-th API request of the case
logn() { logline | grep -Ec "^[0-9-]{10} [0-9:]{8} channel=$1 app=$2 reason=$3\$"; }
SA=(BRIEFING_BOT_APP_SALA_ADMIN=ops-app BRIEFING_BOT_CHANNEL_SALA_ADMIN=D0FAKE456)   # the sala-admin app mapped, its DM id

# ---- the app posts
fresh; post BRIEFING_CHANNEL=reports -- 'plain post'; a=$(apireq)
if [ "$OUT" = ok ] && [ "$(nreq)" = 1 ] && [ "$(napi)" = 1 ] && [ "$(nhook)" = 0 ] && [ "$(cat "$T/req/$a.auth")" = "Bearer $TOKEN" ] \
   && body_eq "$T/req/$a.body" '{"channel":"reports","text":"plain post","unfurl_links":false,"unfurl_media":false}' && [ -z "$(logline)" ]; then
    ok "a mapped channel: chat.postMessage with the Bearer header, the channel, the text and the unfurl flags; no other request; no log line; ok"
else bad "bot post: out=$OUT requests=$(nreq) api=$(napi) hook=$(nhook) body=$(cat "$T/req/$a.body" 2>/dev/null)"; fi

# a thread reply: the same app, a reply in the thread of its DM (no webhook, no channel thread)
fresh; post BRIEFING_CHANNEL=reports BRIEFING_THREAD_TS=1760000000.123456 -- 'a reply'; a=$(apireq)
[ "$OUT" = ok ] && [ "$(napi)" = 1 ] && [ "$(nreq)" = 1 ] && [ "$(nhook)" = 0 ] && [ -z "$(logline)" ] \
    && body_eq "$T/req/$a.body" '{"channel":"reports","text":"a reply","thread_ts":"1760000000.123456","unfurl_links":false,"unfurl_media":false}' \
    && ok "BRIEFING_THREAD_TS on a mapped channel: one chat.postMessage with that thread_ts, no other request, no log line" \
    || bad "thread: out=$OUT apis=$(napi) hooks=$(nhook) log=[$(logline)] body=$(cat "$T/req/$a.body" 2>/dev/null)"
fresh; post BRIEFING_CHANNEL=reports BRIEFING_THREAD_TS= -- 'no thread'; a=$(apireq)
body_eq "$T/req/$a.body" '{"channel":"reports","text":"no thread","unfurl_links":false,"unfurl_media":false}' \
    && ok "an empty BRIEFING_THREAD_TS adds no thread_ts" || bad "empty ts: $(cat "$T/req/$a.body" 2>/dev/null)"
fresh; post BRIEFING_CHANNEL=reports BRIEFING_THREAD_TS=abc -- 'bad ts'
undelivered "a thread ts that is not digits.digits" bad_thread_ts reports demo-app 1; [ "$(napi)" = 0 ] || bad "bad ts: the API was called"

fresh; post BRIEFING_CHANNEL=stack-ops -- 'to ops'; a=$(apireq)
[ "$OUT" = ok ] && [ "$(nhook)" = 0 ] && body_eq "$T/req/$a.body" '{"channel":"C0FAKE123","text":"to ops","unfurl_links":false,"unfurl_media":false}' \
    && ok "BRIEFING_BOT_CHANNEL_STACK_OPS gives the channel to post to (STACK_OPS: capitals, dash as underscore)" || bad "bot channel: out=$OUT $(cat "$T/req/$a.body" 2>/dev/null)"
fresh; post SALA_NOTIFY_CHANNEL=reports -- 'by notify channel'; a=$(apireq)
[ "$OUT" = ok ] && [ "$(nhook)" = 0 ] && [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["channel"])' "$T/req/$a.body")" = reports ] \
    && ok "SALA_NOTIFY_CHANNEL names the channel when BRIEFING_CHANNEL is unset" || bad "notify channel: out=$OUT $(cat "$T/req/$a.body" 2>/dev/null)"
fresh; post BRIEFING_CHANNEL=stack-ops BRIEFING_BOT_APP_STACK_OPS=demo-app -- 'env over config'; a=$(apireq)
[ "$OUT" = ok ] && [ -n "$a" ] && ok "the environment over the config line (the app named by BRIEFING_BOT_APP_STACK_OPS)" || bad "env over config: out=$OUT"

# the text is the formatted one (slack_text and the linkers ran first), and the sala-admin DM carries the same text under its notice line
fresh; post BRIEFING_CHANNEL=reports -- $'**bold** and a [link](https://example.com/x)\nsecond line'; a=$(apireq); want=$(text_of "$T/req/$a.body")
[ "$want" != $'**bold** and a [link](https://example.com/x)\nsecond line' ] && ok "the app's post carries the formatted text (the bold and the link were rewritten for Slack)" || bad "text not formatted: [$want]"
fresh; post "${SA[@]}" BRIEFING_CHANNEL=other -- $'**bold** and a [link](https://example.com/x)\nsecond line'; a=$(apireq)
[ "$(text_of "$T/req/$a.body")" = "[post for channel other had no app mapped]"$'\n'"$want" ] \
    && ok "the sala-admin DM carries the same formatted text under its notice line" || bad "text differs: want [$want] got [$(text_of "$T/req/$a.body")]"

# ---- no app for the channel
fresh; post BRIEFING_CHANNEL=other -- 'unmapped'
undelivered "a channel with no app, the sala-admin app not mapped" no_app_mapped other -; [ "$(napi)" = 0 ] || bad "unmapped: the API was called"
fresh; post -- 'no channel'
undelivered "no channel at all, the sala-admin app not mapped" no_app_mapped sala-admin -; [ "$(napi)" = 0 ] || bad "no channel: the API was called"
fresh; post BRIEFING_CHANNEL=Reports -- 'bad name'
undelivered "a channel name that does not match [a-z0-9-]+, the sala-admin app not mapped" no_app_mapped - -; [ "$(napi)" = 0 ] || bad "bad name: the API was called"
fresh; post "${SA[@]}" BRIEFING_CHANNEL=other -- 'unmapped'; a=$(apireq)
[ "$OUT" = ok ] && [ "$(napi)" = 1 ] && [ "$(nhook)" = 0 ] && [ -z "$(logline)" ] \
    && body_eq "$T/req/$a.body" '{"channel":"D0FAKE456","text":"[post for channel other had no app mapped]\nunmapped","unfurl_links":false,"unfurl_media":false}' \
    && ok "a channel with no app, the sala-admin app mapped: its DM gets the text under [post for channel other had no app mapped]" || bad "unmapped + sala-admin: out=$OUT api=$(napi) log=[$(logline)]"
fresh; post "${SA[@]}" BRIEFING_CHANNEL=Reports -- 'bad name'; a=$(apireq)
[ "$OUT" = ok ] && [ "$(napi)" = 1 ] && body_eq "$T/req/$a.body" '{"channel":"D0FAKE456","text":"[post for channel - had no app mapped]\nbad name","unfurl_links":false,"unfurl_media":false}' \
    && ok "a channel name outside [a-z0-9-]+ is shown as - in the notice line" || bad "bad name + sala-admin: out=$OUT $(cat "$T/req/$a.body" 2>/dev/null)"

# ---- a post that names no channel is the channel sala-admin: its app, its DM id
fresh; post "${SA[@]}" -- 'no channel, sala-admin mapped'; a=$(apireq)
[ "$OUT" = ok ] && [ "$(nreq)" = 1 ] && [ "$(napi)" = 1 ] && [ "$(nhook)" = 0 ] && [ "$(cat "$T/req/$a.auth")" = "Bearer $TOKEN" ] \
    && body_eq "$T/req/$a.body" '{"channel":"D0FAKE456","text":"no channel, sala-admin mapped","unfurl_links":false,"unfurl_media":false}' && [ -z "$(logline)" ] \
    && ok "no channel + sala-admin mapped: chat.postMessage to BRIEFING_BOT_CHANNEL_SALA_ADMIN with the Bearer header and the text; no other request; no log line; ok" \
    || bad "no channel, mapped: out=$OUT requests=$(nreq) api=$(napi) hook=$(nhook) log=[$(logline)] body=$(cat "$T/req/$a.body" 2>/dev/null)"
fresh; post "${SA[@]}" BRIEFING_CHANNEL= SALA_NOTIFY_CHANNEL= -- 'both empty'; a=$(apireq)
[ "$OUT" = ok ] && [ "$(napi)" = 1 ] && [ "$(nhook)" = 0 ] && body_eq "$T/req/$a.body" '{"channel":"D0FAKE456","text":"both empty","unfurl_links":false,"unfurl_media":false}' \
    && ok "BRIEFING_CHANNEL and SALA_NOTIFY_CHANNEL both empty count as no channel" || bad "both empty: out=$OUT api=$(napi) hook=$(nhook)"
fresh; post "${SA[@]}" BRIEFING_CHANNEL=reports -- 'named channel'; a=$(apireq)
[ "$OUT" = ok ] && [ "$(napi)" = 1 ] && [ "$(nhook)" = 0 ] && body_eq "$T/req/$a.body" '{"channel":"reports","text":"named channel","unfurl_links":false,"unfurl_media":false}' \
    && ok "the sala-admin mapping does not leak onto a named channel: reports posts to reports as its own app" || bad "named channel: out=$OUT $(cat "$T/req/$a.body" 2>/dev/null)"
fresh; post "${SA[@]}" BRIEFING_THREAD_TS=1760000000.123456 -- 'a reply, no channel'; a=$(apireq)
[ "$OUT" = ok ] && [ "$(napi)" = 1 ] && [ "$(nhook)" = 0 ] && [ -z "$(logline)" ] \
    && body_eq "$T/req/$a.body" '{"channel":"D0FAKE456","text":"a reply, no channel","thread_ts":"1760000000.123456","unfurl_links":false,"unfurl_media":false}' \
    && ok "no channel + sala-admin mapped + BRIEFING_THREAD_TS: a reply in the thread of the sala-admin DM" || bad "no channel thread: out=$OUT apis=$(napi) hooks=$(nhook) log=[$(logline)]"
fresh; rm -f "$T/tok/slack-bot-token-ops-app"; post "${SA[@]}" -- 'text for no channel, token missing'
undelivered "no channel + sala-admin mapped, token missing" no_token_file sala-admin ops-app; [ "$(napi)" = 0 ] || bad "no channel, token missing: the API was called"
mk_token ops-app 600 "$TOKEN"$'\n'
{ cat "$T/config"; printf 'BRIEFING_BOT_APP_SALA_ADMIN=ops-app\nBRIEFING_BOT_CHANNEL_SALA_ADMIN=D0FAKE456\n'; } > "$T/config3"
fresh; OUT=$(SALA_CONFIG="$T/config3" env -u BRIEFING_CHANNEL -u SALA_NOTIFY_CHANNEL bash -c '. "$1/lib.sh" 2>/dev/null; post_slack "from config lines"' _ "$D" 2>&1); a=$(apireq)
[ "$OUT" = ok ] && [ "$(napi)" = 1 ] && [ "$(nhook)" = 0 ] && body_eq "$T/req/$a.body" '{"channel":"D0FAKE456","text":"from config lines","unfurl_links":false,"unfurl_media":false}' \
    && ok "no channel + sala-admin mapped by config lines (environment unset): the app posts to the DM id" || bad "config lines: out=$OUT api=$(napi) hook=$(nhook) $(cat "$T/req/$a.body" 2>/dev/null)"

# ---- the order when an app fails: the app again (a failure a second try could change), then the sala-admin app's DM, then nothing
WANT_NOTICE=$'[post for app demo-app could not be delivered: slack_error:channel_not_found]\nthe post'

# (a) the first attempt fails with http_500, the retry succeeds: two API calls to the app's DM
fresh; seq_answer 1 500 '{"ok":true}'; post "${SA[@]}" BRIEFING_CHANNEL=reports -- 'the post'
[ "$OUT" = ok ] && [ "$(napi)" = 2 ] && [ "$(nhook)" = 0 ] && [ "$(apfield 1 channel)" = reports ] && [ "$(apfield 2 channel)" = reports ] \
    && [ "$(apfield 2 text)" = 'the post' ] && [ "$(logline | wc -l)" = 1 ] && [ "$(logn reports demo-app http_500)" = 1 ] \
    && ok "(a) first attempt http_500, the retry succeeds: two API calls to the app's DM, ok; the failed attempt is logged" \
    || bad "(a) retry: out=$OUT api=$(napi) hook=$(nhook) log=[$(logline)]"

# (b) the app fails twice, the sala-admin DM works: the third call goes there with the naming first line and the text
fresh; printf '200\n{"ok":false,"error":"channel_not_found"}' > "$T/answer"; seq_answer 3 200 '{"ok":true}'; post "${SA[@]}" BRIEFING_CHANNEL=reports -- 'the post'
[ "$OUT" = ok ] && [ "$(napi)" = 3 ] && [ "$(nhook)" = 0 ] && [ "$(apfield 1 channel)" = reports ] && [ "$(apfield 2 channel)" = reports ] \
    && [ "$(apfield 3 channel)" = D0FAKE456 ] && [ "$(apfield 3 text)" = "$WANT_NOTICE" ] && [ "$(cat "$T/req/$(apin 3).auth")" = "Bearer $TOKEN" ] \
    && [ "$(logline | wc -l)" = 2 ] && [ "$(logn reports demo-app slack_error:channel_not_found)" = 2 ] \
    && ok "(b) the app fails twice: the third call goes to the sala-admin DM with the failed app and reason on a first line, then the text; two log lines" \
    || bad "(b) sala-admin DM: out=$OUT api=$(napi) hook=$(nhook) log=[$(logline)] text=[$(apfield 3 text 2>/dev/null)]"

# (c) every DM fails: nothing delivered, no webhook request, one log line per attempt
fresh; printf '200\n{"ok":false,"error":"channel_not_found"}' > "$T/answer"; post "${SA[@]}" BRIEFING_CHANNEL=reports -- 'the post'
[ "$RC" != 0 ] && [ -z "$OUT" ] && [ "$(napi)" = 3 ] && [ "$(nreq)" = 3 ] && [ "$(nhook)" = 0 ] \
    && [ "$(logline | wc -l)" = 3 ] && [ "$(logn reports demo-app slack_error:channel_not_found)" = 2 ] && [ "$(logn sala-admin ops-app slack_error:channel_not_found)" = 1 ] \
    && ok "(c) every DM fails: exit $RC, no output, no webhook request; one log line per attempt (the app twice, the sala-admin app once)" \
    || bad "(c) all fail: rc=$RC out=[$OUT] api=$(napi) hook=$(nhook) log=[$(logline)]"

# (d) a local refusal is not retried: one attempt (no API call), then the sala-admin DM with the reason
fresh; rm -f "$T/tok/slack-bot-token-demo-app"; post "${SA[@]}" BRIEFING_CHANNEL=reports -- 'the post'
[ "$OUT" = ok ] && [ "$(napi)" = 1 ] && [ "$(nhook)" = 0 ] && [ "$(apfield 1 channel)" = D0FAKE456 ] \
    && [ "$(apfield 1 text)" = $'[post for app demo-app could not be delivered: no_token_file]\nthe post' ] \
    && [ "$(logline | wc -l)" = 1 ] && [ "$(logn reports demo-app no_token_file)" = 1 ] \
    && ok "(d) a missing token file is not retried: one attempt, then the sala-admin DM (the only API call) with no_token_file named" \
    || bad "(d) local refusal: out=$OUT api=$(napi) hook=$(nhook) log=[$(logline)]"
fresh; mk_token demo-app 644 "$TOKEN"$'\n'; post "${SA[@]}" BRIEFING_CHANNEL=reports -- 'the post'
[ "$OUT" = ok ] && [ "$(napi)" = 1 ] && [ "$(apfield 1 channel)" = D0FAKE456 ] && [ "$(logline | wc -l)" = 1 ] && [ "$(logn reports demo-app token_mode_644)" = 1 ] \
    && ok "(d) a loose-mode token file is not retried either, and its token is never sent" || bad "(d) mode 644 with sala-admin: out=$OUT api=$(napi) log=[$(logline)]"
mk_token demo-app 600 "$TOKEN"$'\n'

# (e) the failed app is sala-admin itself: retried once, then nothing, no loop through sala-admin again
fresh; printf '200\n{"ok":false,"error":"channel_not_found"}' > "$T/answer"; post "${SA[@]}" -- 'the post'
[ "$RC" != 0 ] && [ -z "$OUT" ] && [ "$(napi)" = 2 ] && [ "$(nreq)" = 2 ] && [ "$(nhook)" = 0 ] \
    && [ "$(apfield 1 channel)" = D0FAKE456 ] && [ "$(apfield 2 channel)" = D0FAKE456 ] && [ "$(logline | wc -l)" = 2 ] && [ "$(logn sala-admin ops-app slack_error:channel_not_found)" = 2 ] \
    && ok "(e) sala-admin's own post fails: one retry, then exit $RC with no output and no webhook request; no self-loop" \
    || bad "(e) sala-admin itself: rc=$RC out=[$OUT] api=$(napi) hook=$(nhook) log=[$(logline)]"

# (f) the sala-admin app unmapped: the app fails twice, then nothing
fresh; printf '200\n{"ok":false,"error":"channel_not_found"}' > "$T/answer"; post BRIEFING_CHANNEL=reports -- 'the post'
[ "$RC" != 0 ] && [ -z "$OUT" ] && [ "$(napi)" = 2 ] && [ "$(nreq)" = 2 ] && [ "$(nhook)" = 0 ] \
    && [ "$(logline | wc -l)" = 2 ] && [ "$(logn reports demo-app slack_error:channel_not_found)" = 2 ] \
    && ok "(f) sala-admin unmapped: the app fails twice, then exit $RC with no output and no webhook request" || bad "(f) sala-admin unmapped: rc=$RC out=[$OUT] api=$(napi) hook=$(nhook) log=[$(logline)]"

# (g) a thread reply whose app fails twice: the retry stays in the thread, the sala-admin DM is a plain post (the thread is in another DM)
fresh; printf '200\n{"ok":false,"error":"channel_not_found"}' > "$T/answer"; seq_answer 3 200 '{"ok":true}'
post "${SA[@]}" BRIEFING_CHANNEL=reports BRIEFING_THREAD_TS=1760000000.123456 -- 'the post'
[ "$OUT" = ok ] && [ "$(napi)" = 3 ] && [ "$(nhook)" = 0 ] \
    && body_eq "$T/req/$(apin 1).body" '{"channel":"reports","text":"the post","thread_ts":"1760000000.123456","unfurl_links":false,"unfurl_media":false}' \
    && body_eq "$T/req/$(apin 2).body" '{"channel":"reports","text":"the post","thread_ts":"1760000000.123456","unfurl_links":false,"unfurl_media":false}' \
    && body_eq "$T/req/$(apin 3).body" '{"channel":"D0FAKE456","text":"[post for app demo-app could not be delivered: slack_error:channel_not_found]\nthe post","unfurl_links":false,"unfurl_media":false}' \
    && ok "(g) a thread reply that fails twice: both tries carry thread_ts, the sala-admin DM carries none" || bad "(g) thread fallback: out=$OUT api=$(napi) hook=$(nhook) log=[$(logline)]"

# ---- the app cannot post and nothing else can: not delivered, the log says why (a local refusal is one attempt)
fresh; rm -f "$T/tok/slack-bot-token-demo-app"; post BRIEFING_CHANNEL=reports -- 'text for token missing'
undelivered "token missing" no_token_file; [ "$(napi)" = 0 ] || bad "token missing: the API was called"
fresh; mk_token demo-app 644 "$TOKEN"$'\n'; post BRIEFING_CHANNEL=reports -- 'text for mode 644'
undelivered "mode 644" token_mode_644; [ "$(napi)" = 0 ] && ok "mode 644: the token was never sent" || bad "mode 644: the API was called ($(napi))"
fresh; mk_token demo-app 660 "$TOKEN"$'\n'; post BRIEFING_CHANNEL=reports -- 'text for mode 660'
undelivered "mode 660" token_mode_660
fresh; mk_token demo-app 400 "$TOKEN"$'\n'; post BRIEFING_CHANNEL=reports -- 'ok at 400'
[ "$OUT" = ok ] && [ "$(napi)" = 1 ] && [ "$(nhook)" = 0 ] && ok "mode 400 is fine (600 or stricter)" || bad "mode 400: out=$OUT api=$(napi) hook=$(nhook)"
fresh; mk_token demo-app 600 ""; post BRIEFING_CHANNEL=reports -- 'text for empty token'
undelivered "empty token" token_empty; [ "$(napi)" = 0 ] || bad "empty token: the API was called"
fresh; mk_token demo-app 600 $' \n\t\n'; post BRIEFING_CHANNEL=reports -- 'text for blank token'
undelivered "blank token" token_empty
fresh; rm -f "$T/tok/slack-bot-token-demo-app"; mkdir "$T/tok/slack-bot-token-demo-app"; post BRIEFING_CHANNEL=reports -- 'text for token folder'
undelivered "token path is a folder" no_token_file; rm -rf "$T/tok/slack-bot-token-demo-app"; mk_token demo-app 600 "$TOKEN"$'\n'
fresh; post BRIEFING_CHANNEL=badapp -- 'text for bad app'
undelivered "an app name that is not a plain name" bad_app_name badapp -; [ "$(napi)" = 0 ] || bad "bad app name: the API was called"
fresh; post BRIEFING_CHANNEL=badch -- 'text for bad channel setting'
undelivered "a channel setting that is not a channel" bad_channel_setting badch demo-app; [ "$(napi)" = 0 ] || bad "bad channel setting: the API was called"

# ---- Slack or the network refuses: the app was tried twice, then nothing
fresh; printf '200\n{"ok":false,"error":"invalid_auth"}' > "$T/answer"; post BRIEFING_CHANNEL=reports -- 'text for ok false'
undelivered "Slack ok:false" 'slack_error:invalid_auth' reports demo-app 2; [ "$(napi)" = 2 ] && ok "ok:false: the app was tried twice" || bad "ok false: api calls $(napi)"
fresh; printf '200\n{"ok":false,"error":"x y; echo hacked","warning":"%s"}' "$TOKEN" > "$T/answer"; post BRIEFING_CHANNEL=reports -- 'text for odd error'
undelivered "an error text that is not a code" 'slack_error:unknown_error' reports demo-app 2
fresh; printf '500\n{"ok":true}' > "$T/answer"; post BRIEFING_CHANNEL=reports -- 'text for http 500'
undelivered "HTTP 500 (even with ok:true in the body)" http_500 reports demo-app 2
fresh; printf '429\n{"ok":false,"error":"ratelimited"}' > "$T/answer"; post BRIEFING_CHANNEL=reports -- 'text for http 429'
undelivered "HTTP 429" http_429 reports demo-app 2
fresh; printf '200\n<html>not json</html>' > "$T/answer"; post BRIEFING_CHANNEL=reports -- 'text for not json'
undelivered "an answer that is not JSON" bad_response reports demo-app 2
fresh; printf '200\n{"ok":"true"}' > "$T/answer"; post BRIEFING_CHANNEL=reports -- 'text for ok string'
undelivered "ok that is not true" 'slack_error:unknown_error' reports demo-app 2
fresh; post BRIEFING_CHANNEL=reports SALA_DM_API_BASE=http://127.0.0.1:9/api -- 'text for refused'
undelivered "a refused connection" network reports demo-app 2; [ "$(napi)" = 0 ] || bad "refused: the API was called"
fresh; post BRIEFING_CHANNEL=reports SALA_DM_API_BASE=http://127.0.0.1:$PORT/redir -- 'text for redirect'
undelivered "a redirect" http_302 reports demo-app 2
n=0; for f in "$T"/req/*.path; do [ "$(cat "$f")" = /api/chat.postMessage ] && n=$((n + 1)); done
[ "$n" = 0 ] && ok "a redirect is not followed: the token went nowhere else" || bad "the redirect was followed ($n calls to /api)"

# ---- BRIEFING_NO_POST: nothing is sent, no token is read
fresh; chmod 000 "$T/tok/slack-bot-token-demo-app"; post BRIEFING_CHANNEL=reports BRIEFING_NO_POST=1 -- 'a dry run'; chmod 600 "$T/tok/slack-bot-token-demo-app"
[ "$OUT" = "not posted (BRIEFING_NO_POST)" ] && [ "$(nreq)" = 0 ] && grep -q '^a dry run$' "$T/blog/would-post.log" && [ -z "$(logline)" ] \
    && ok "BRIEFING_NO_POST: the text goes to would-post.log, nothing is sent, no log line (the token file was not touched)" || bad "no post: out=$OUT requests=$(nreq) log=[$(logline)]"

# ---- reply.sh: a reply in the thread of the reports app's DM, with or without the app's token
fresh; OUT=$(env -u SALA_NOTIFY_CHANNEL -u BRIEFING_CHANNEL "$D/reply.sh" 1760000000.123456 'Done' 2>&1); RC=$?; a=$(apireq); printf '%s\n' "$OUT" >> "$T/all.out"
[ "$OUT" = ok ] && [ "$RC" = 0 ] && [ "$(napi)" = 1 ] && [ "$(nreq)" = 1 ] && [ "$(nhook)" = 0 ] && [ -z "$(logline)" ] \
    && body_eq "$T/req/$a.body" '{"channel":"reports","text":"Done","thread_ts":"1760000000.123456","unfurl_links":false,"unfurl_media":false}' \
    && ok "reply.sh: the thread reply is the reports app's chat.postMessage with its thread_ts; no other request, no log line" || bad "reply.sh: out=$OUT rc=$RC apis=$(napi) hooks=$(nhook) log=[$(logline)] $(cat "$T/req/$a.body" 2>/dev/null)"
fresh; rm -f "$T/tok/slack-bot-token-demo-app"; OUT=$(env -u SALA_NOTIFY_CHANNEL -u BRIEFING_CHANNEL "$D/reply.sh" 1760000000.123456 'Done' 2>&1); RC=$?; printf '%s\n' "$OUT" >> "$T/all.out"
undelivered "reply.sh without the token" no_token_file reports demo-app 1; [ "$RC" = 1 ] && [ "$(napi)" = 0 ] && ok "reply.sh without the token: exit 1, no API call" || bad "reply.sh no token: rc=$RC api=$(napi)"
mk_token demo-app 600 "$TOKEN"$'\n'
fresh; OUT=$(env -u SALA_NOTIFY_CHANNEL -u BRIEFING_CHANNEL "$D/reply.sh" not-a-ts 'Done' 2>&1); RC=$?
[ "$RC" = 2 ] && [ "$(nreq)" = 0 ] && ok "reply.sh with a bad ts: exit 2 before anything is posted" || bad "reply.sh bad ts: rc=$RC out=$OUT requests=$(nreq)"

# ---- the settings from the sala config, the environment unset
mkdir -p "$T/tok2"; printf '%s\n' "$TOKEN" > "$T/tok2/slack-bot-token-demo-app"; chmod 600 "$T/tok2/slack-bot-token-demo-app"
{ cat "$T/config"; printf 'SALA_DM_TOKEN_DIR=%s\nSALA_DM_API_BASE=%s/\n' "$T/tok2" "$API"; } > "$T/config2"
fresh; rm -f "$T/tok/slack-bot-token-demo-app"
unset_env=(-u SALA_DM_TOKEN_DIR -u SALA_DM_API_BASE)
fresh; OUT=$(env "${unset_env[@]}" SALA_CONFIG="$T/config2" BRIEFING_CHANNEL=reports bash -c '. "$1/lib.sh" 2>/dev/null; post_slack "from the config"' _ "$D" 2>&1); a=$(apireq)
[ "$OUT" = ok ] && [ "$(nhook)" = 0 ] && [ "$(cat "$T/req/$a.auth" 2>/dev/null)" = "Bearer $TOKEN" ] \
    && ok "SALA_DM_TOKEN_DIR and SALA_DM_API_BASE are read from the sala config (a trailing / on the base is fine)" || bad "config settings: out=$OUT api=$(napi) hook=$(nhook)"
mk_token demo-app 600 "$TOKEN"$'\n'

# ---- a copy of contrib/briefing alone: no lib/dm.sh beside it
mkdir -p "$T/alone"; cp -r "$D" "$T/alone/briefing"
fresh; LIBDIR=$T/alone/briefing post BRIEFING_CHANNEL=reports -- 'alone'; a=$(apireq)
[ "$OUT" = ok ] && [ "$(nhook)" = 0 ] && [ "$(cat "$T/req/$a.auth" 2>/dev/null)" = "Bearer $TOKEN" ] \
    && ok "contrib/briefing copied alone (no lib/dm.sh): the app still posts, same token folder and API base settings" || bad "alone: out=$OUT api=$(napi) hook=$(nhook)"

# ---- the token is nowhere it could be read from: sampled while a post is in flight (the listener holds the answer 1.5 s)
fresh; : > "$T/delay"
( sleep 0.7; cat /proc/[0-9]*/cmdline /proc/[0-9]*/environ 2>/dev/null | tr '\0' '\n' > "$T/procs.txt" ) &
SAMPLER=$!
post BRIEFING_CHANNEL=reports -- 'in flight'; wait "$SAMPLER"
[ "$OUT" = ok ] && [ "$(nhook)" = 0 ] && grep -qF -- "$T/tok" "$T/procs.txt" \
    && ok "the post was in flight while the process table was sampled (the app's call took the 1.5 s)" || bad "in flight: out=$OUT hooks=$(nhook) sample has the token folder: $(grep -cF -- "$T/tok" "$T/procs.txt" 2>/dev/null)"
n=$(grep -c 'xoxb-test-FAKE[1]23' "$T/procs.txt")
[ "$n" = 0 ] && ok "the token is in no process's argument list or environment (sampled, $(wc -l < "$T/procs.txt") lines)" || bad "the token was in $n lines of the process table"
n=$(cat "$T/all.out" "$T"/blog/* 2>/dev/null | grep -c 'xoxb-test-FAKE[1]23')
[ "$n" = 0 ] && ok "the token is in no output and no log of any case above" || bad "the token was printed or logged ($n lines)"
n=$(cat "$T/all.out" "$T"/blog/* 2>/dev/null | grep -c '127\.0\.0\.1')
[ "$n" = 0 ] && ok "no webhook or API address in any output or log" || bad "an address was printed or logged ($n lines)"
[ ! -e "$T/hookhit" ] && ok "no request to a webhook path in the whole run" || bad "a webhook path was requested: $(cat "$T/hookhit")"
exit $fail
