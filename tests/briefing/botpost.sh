#!/usr/bin/env bash
# Posts through a channel's Slack app: post_slack posts a channel that has an app mapped (BRIEFING_BOT_APP_<NAME>) with that app's bot
# token (chat.postMessage; the token file is the one `sala dm` reads), and sends the same text through the webhook whenever that cannot
# be done, so a post is never lost. One listener on 127.0.0.1 plays both the Slack API (/api/...) and the webhook (/hook...), recording
# each request's path, Authorization header and body; the API's answer is whatever the case puts in a file. Checked:
#   - the token file present: chat.postMessage with the Bearer header, the channel (its name, or BRIEFING_BOT_CHANNEL_<NAME>), the text
#     and the two unfurl flags, no thread_ts; the webhook is not hit; answer "ok"; no log line;
#     SALA_NOTIFY_CHANNEL names the channel too; the text is the one the webhook gets
#   - BRIEFING_THREAD_TS set (a thread reply, reply.sh): no chat.postMessage at all, one webhook post with thread_ts, no log line (the
#     thread's parent is a channel message and the app is not in the channel); an empty BRIEFING_THREAD_TS is no thread: the app posts
#   - no mapping (a channel without a setting, no channel at all): the webhook only, no log line
#   - token file missing / mode 644 / empty / a folder, an app name that is not a plain name, a bad channel setting: the webhook gets the
#     same text and bot-post.log gets one line (time, channel, app, reason); a loose-mode token is never sent anywhere
#   - Slack answers ok:false (its error code is logged and nothing else of the answer), HTTP 500, a redirect (never followed, so the
#     token goes nowhere else), an answer that is not JSON, a refused connection: the webhook, and the log line
#   - BRIEFING_NO_POST: nothing is sent; the text goes to would-post.log
#   - the settings from the sala config (SALA_DM_TOKEN_DIR, SALA_DM_API_BASE and the mapping), with the environment unset
#   - a copy of contrib/briefing alone (no lib/dm.sh beside it) still posts through the app
#   - the token is in no output, no log, no process's argument list or environment (sampled while a post is in flight)
# Fake values only (xoxb-test-FAKE123, a temporary folder locked while the test runs, removed at the end); nothing leaves the box.
# Usage: bash tests/briefing/botpost.sh   (exit 0 = pass; a few seconds)
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd); D=$ROOT/contrib/briefing
fail=0; ok() { echo "  ok   $*"; }; bad() { echo "  FAIL $*"; fail=1; }
T=$(mktemp -d); trap 'kill "${SRV:-}" 2>/dev/null; rm -rf "$T"' EXIT
exec 8<"$T"; flock -n 8   # systemd-tmpfiles ageing honours a held flock on the folder
unset SALA_NOTIFY_CMD SALA_WATCH_NOTIFY_CMD SALA_STACKSHOT_WEB SALA_NOTIFY_CHANNEL BRIEFING_CHANNEL BRIEFING_THREAD_TS BRIEFING_NO_POST \
      BRIEFING_WEBHOOK_FILE BRIEFING_GMAIL_CONNECTOR BRIEFING_FORWARD_LABEL SALA_DM_TOKEN_DIR SALA_DM_API_BASE XDG_CONFIG_HOME \
      $(compgen -v | grep -E '^BRIEFING_(WEBHOOK_FILE|BOT_APP|BOT_CHANNEL)_')
mkdir -p "$T/home" "$T/blog" "$T/tok" "$T/req"
export HOME=$T/home
TOKEN=xoxb-test-FAKE123

# the listener: /api/chat.postMessage answers from $T/answer (first line the HTTP status, the rest the body; none: 200 and ok:true),
# after a pause when $T/delay exists; /redir/chat.postMessage redirects to /api/chat.postMessage; any other path (the webhooks) answers ok
python3 - "$T/port" "$T/req" "$T/answer" "$T/delay" <<'PY' &
import http.server, os, sys, time
port_file, base, answer, delay = sys.argv[1:5]
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
        if self.path == "/api/chat.postMessage":
            if os.path.exists(delay): time.sleep(1.5)
            status, out = 200, b'{"ok":true,"ts":"1760000000.000100"}'
            if os.path.exists(answer):
                head, _, rest = open(answer, "rb").read().partition(b"\n")
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

printf 'http://127.0.0.1:%s/hook-default\n' "$PORT" > "$T/wh-default"
printf 'http://127.0.0.1:%s/hook-reports\n' "$PORT" > "$T/wh-reports"
printf 'http://127.0.0.1:%s/hook-ops\n' "$PORT" > "$T/wh-ops"
cat > "$T/config" <<EOF
BRIEFING_WEBHOOK_FILE=$T/wh-default
BRIEFING_WEBHOOK_FILE_REPORTS=$T/wh-reports
BRIEFING_WEBHOOK_FILE_STACK_OPS=$T/wh-ops
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
fresh() { rm -f "$T"/req/* "$T/answer" "$T/delay" "$T/blog/bot-post.log" "$T/blog/would-post.log"; }
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
# fellback <label> <reason> [channel app]: the post went to the webhook with the text, and the log line says why
fellback() {
    local label=$1 reason=$2 ch=${3:-reports} app=${4:-demo-app} h
    h=$(hookreq)
    if [ "$OUT" = ok ] && [ -n "$h" ] && [ "$(nhook)" = 1 ] && [ "$(text_of "$T/req/$h.body")" = "$LAST" ] \
       && [ "$(logline | wc -l)" = 1 ] && logline | grep -Eq "^[0-9-]{10} [0-9:]{8} channel=$ch app=$app reason=$reason\$"; then
        ok "$label: the webhook got the text; bot-post.log: $(logline | cut -d' ' -f3-)"
    else bad "$label: out=$OUT hooks=$(nhook) apis=$(napi) log=[$(logline)]"; fi
}

# ---- the app posts
fresh; post BRIEFING_CHANNEL=reports -- 'plain post'; a=$(apireq)
if [ "$OUT" = ok ] && [ "$(nreq)" = 1 ] && [ "$(napi)" = 1 ] && [ "$(nhook)" = 0 ] && [ "$(cat "$T/req/$a.auth")" = "Bearer $TOKEN" ] \
   && body_eq "$T/req/$a.body" '{"channel":"reports","text":"plain post","unfurl_links":false,"unfurl_media":false}' && [ -z "$(logline)" ]; then
    ok "a mapped channel: chat.postMessage with the Bearer header, the channel, the text and the unfurl flags; no webhook; no log line; ok"
else bad "bot post: out=$OUT requests=$(nreq) api=$(napi) hook=$(nhook) body=$(cat "$T/req/$a.body" 2>/dev/null)"; fi

# a thread reply never goes through the app (its parent is a channel message, the app is not a member of the channel): the webhook gets it
fresh; post BRIEFING_CHANNEL=reports BRIEFING_THREAD_TS=1760000000.123456 -- 'a reply'; h=$(hookreq)
[ "$OUT" = ok ] && [ "$(napi)" = 0 ] && [ "$(nhook)" = 1 ] && [ "$(nreq)" = 1 ] && [ "$(cat "$T/req/$h.path")" = /hook-reports ] \
    && body_eq "$T/req/$h.body" '{"text":"a reply","thread_ts":"1760000000.123456","unfurl_links":false,"unfurl_media":false}' && [ -z "$(logline)" ] \
    && ok "BRIEFING_THREAD_TS on a mapped channel: no chat.postMessage, one webhook post with thread_ts, no bot-post.log line" \
    || bad "thread: out=$OUT apis=$(napi) hooks=$(nhook) log=[$(logline)] body=$(cat "$T/req/$h.body" 2>/dev/null)"
fresh; post BRIEFING_CHANNEL=reports BRIEFING_THREAD_TS= -- 'no thread'; a=$(apireq)
body_eq "$T/req/$a.body" '{"channel":"reports","text":"no thread","unfurl_links":false,"unfurl_media":false}' \
    && ok "an empty BRIEFING_THREAD_TS adds no thread_ts" || bad "empty ts: $(cat "$T/req/$a.body" 2>/dev/null)"

fresh; post BRIEFING_CHANNEL=stack-ops -- 'to ops'; a=$(apireq)
[ "$OUT" = ok ] && [ "$(nhook)" = 0 ] && body_eq "$T/req/$a.body" '{"channel":"C0FAKE123","text":"to ops","unfurl_links":false,"unfurl_media":false}' \
    && ok "BRIEFING_BOT_CHANNEL_STACK_OPS gives the channel to post to (STACK_OPS: capitals, dash as underscore)" || bad "bot channel: out=$OUT $(cat "$T/req/$a.body" 2>/dev/null)"
fresh; post SALA_NOTIFY_CHANNEL=reports -- 'by notify channel'; a=$(apireq)
[ "$OUT" = ok ] && [ "$(nhook)" = 0 ] && [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["channel"])' "$T/req/$a.body")" = reports ] \
    && ok "SALA_NOTIFY_CHANNEL names the channel when BRIEFING_CHANNEL is unset" || bad "notify channel: out=$OUT $(cat "$T/req/$a.body" 2>/dev/null)"
fresh; post BRIEFING_CHANNEL=stack-ops BRIEFING_BOT_APP_STACK_OPS=demo-app -- 'env over config'; a=$(apireq)
[ "$OUT" = ok ] && [ -n "$a" ] && ok "the environment over the config line (the app named by BRIEFING_BOT_APP_STACK_OPS)" || bad "env over config: out=$OUT"

# the same formatted text as the webhook path: a channel without an app sends it through the webhook, the mapped one through the app
fresh; post BRIEFING_CHANNEL=other -- $'**bold** and a [link](https://example.com/x)\nsecond line'; h=$(hookreq); want=$(text_of "$T/req/$h.body")
fresh; post BRIEFING_CHANNEL=reports -- $'**bold** and a [link](https://example.com/x)\nsecond line'; a=$(apireq)
[ "$(text_of "$T/req/$a.body")" = "$want" ] && [ "$want" != $'**bold** and a [link](https://example.com/x)\nsecond line' ] \
    && ok "the app's post carries the text the webhook gets (slack_text and the linkers ran first)" || bad "text differs: webhook [$want] app [$(text_of "$T/req/$a.body")]"

# ---- no mapping: the webhook only
fresh; post BRIEFING_CHANNEL=other -- 'unmapped'; h=$(hookreq)
[ "$OUT" = ok ] && [ "$(nreq)" = 1 ] && [ "$(napi)" = 0 ] && [ "$(cat "$T/req/$h.path")" = /hook-default ] && [ -z "$(logline)" ] \
    && ok "a channel with no app: the webhook only, no API call, no log line" || bad "unmapped: out=$OUT api=$(napi) hook=$(nhook) log=[$(logline)]"
fresh; post -- 'no channel'
[ "$OUT" = ok ] && [ "$(napi)" = 0 ] && [ "$(nhook)" = 1 ] && [ -z "$(logline)" ] && ok "no channel at all: the webhook only" || bad "no channel: out=$OUT api=$(napi) hook=$(nhook)"
fresh; post BRIEFING_CHANNEL=Reports -- 'bad name'
[ "$OUT" = ok ] && [ "$(napi)" = 0 ] && [ "$(nhook)" = 1 ] && ok "a channel name that does not match [a-z0-9-]+: the webhook only" || bad "bad name: out=$OUT api=$(napi)"

# ---- the app cannot post: the webhook gets the text, the log says why
fresh; rm -f "$T/tok/slack-bot-token-demo-app"; post BRIEFING_CHANNEL=reports -- 'text for token missing'
fellback "token missing" no_token_file; [ "$(napi)" = 0 ] || bad "token missing: the API was called"
fresh; mk_token demo-app 644 "$TOKEN"$'\n'; post BRIEFING_CHANNEL=reports -- 'text for mode 644'
fellback "mode 644" token_mode_644; [ "$(napi)" = 0 ] && ok "mode 644: the token was never sent" || bad "mode 644: the API was called ($(napi))"
fresh; mk_token demo-app 660 "$TOKEN"$'\n'; post BRIEFING_CHANNEL=reports -- 'text for mode 660'
fellback "mode 660" token_mode_660
fresh; mk_token demo-app 400 "$TOKEN"$'\n'; post BRIEFING_CHANNEL=reports -- 'ok at 400'
[ "$OUT" = ok ] && [ "$(napi)" = 1 ] && [ "$(nhook)" = 0 ] && ok "mode 400 is fine (600 or stricter)" || bad "mode 400: out=$OUT api=$(napi) hook=$(nhook)"
fresh; mk_token demo-app 600 ""; post BRIEFING_CHANNEL=reports -- 'text for empty token'
fellback "empty token" token_empty; [ "$(napi)" = 0 ] || bad "empty token: the API was called"
fresh; mk_token demo-app 600 $' \n\t\n'; post BRIEFING_CHANNEL=reports -- 'text for blank token'
fellback "blank token" token_empty
fresh; rm -f "$T/tok/slack-bot-token-demo-app"; mkdir "$T/tok/slack-bot-token-demo-app"; post BRIEFING_CHANNEL=reports -- 'text for token folder'
fellback "token path is a folder" no_token_file; rm -rf "$T/tok/slack-bot-token-demo-app"; mk_token demo-app 600 "$TOKEN"$'\n'
fresh; post BRIEFING_CHANNEL=badapp -- 'text for bad app'
fellback "an app name that is not a plain name" bad_app_name badapp -; [ "$(napi)" = 0 ] || bad "bad app name: the API was called"
fresh; post BRIEFING_CHANNEL=badch -- 'text for bad channel setting'
fellback "a channel setting that is not a channel" bad_channel_setting badch demo-app; [ "$(napi)" = 0 ] || bad "bad channel setting: the API was called"

# ---- Slack or the network refuses: the app was tried, then the webhook
fresh; printf '200\n{"ok":false,"error":"invalid_auth"}' > "$T/answer"; post BRIEFING_CHANNEL=reports -- 'text for ok false'
fellback "Slack ok:false" 'slack_error:invalid_auth'; [ "$(napi)" = 1 ] && ok "ok:false: the app was tried once" || bad "ok false: api calls $(napi)"
fresh; printf '200\n{"ok":false,"error":"x y; echo hacked","warning":"%s"}' "$TOKEN" > "$T/answer"; post BRIEFING_CHANNEL=reports -- 'text for odd error'
fellback "an error text that is not a code" 'slack_error:unknown_error'
fresh; printf '500\n{"ok":true}' > "$T/answer"; post BRIEFING_CHANNEL=reports -- 'text for http 500'
fellback "HTTP 500 (even with ok:true in the body)" http_500
fresh; printf '429\n{"ok":false,"error":"ratelimited"}' > "$T/answer"; post BRIEFING_CHANNEL=reports -- 'text for http 429'
fellback "HTTP 429" http_429
fresh; printf '200\n<html>not json</html>' > "$T/answer"; post BRIEFING_CHANNEL=reports -- 'text for not json'
fellback "an answer that is not JSON" bad_response
fresh; printf '200\n{"ok":"true"}' > "$T/answer"; post BRIEFING_CHANNEL=reports -- 'text for ok string'
fellback "ok that is not true" 'slack_error:unknown_error'
fresh; post BRIEFING_CHANNEL=reports SALA_DM_API_BASE=http://127.0.0.1:9/api -- 'text for refused'
fellback "a refused connection" network; [ "$(napi)" = 0 ] || bad "refused: the API was called"
fresh; post BRIEFING_CHANNEL=reports SALA_DM_API_BASE=http://127.0.0.1:$PORT/redir -- 'text for redirect'
fellback "a redirect" http_302
n=0; for f in "$T"/req/*.path; do [ "$(cat "$f")" = /api/chat.postMessage ] && n=$((n + 1)); done
[ "$n" = 0 ] && ok "a redirect is not followed: the token went nowhere else" || bad "the redirect was followed ($n calls to /api)"
fresh; printf '200\n{"ok":false,"error":"channel_not_found"}' > "$T/answer"; post BRIEFING_CHANNEL=reports -- 'text for fallback payload'
h=$(hookreq)
body_eq "$T/req/$h.body" '{"text":"text for fallback payload","unfurl_links":false,"unfurl_media":false}' \
    && ok "the fallback payload is the webhook's own, as before" || bad "fallback payload: $(cat "$T/req/$h.body" 2>/dev/null)"

# ---- BRIEFING_NO_POST: nothing is sent, no token is read
fresh; chmod 000 "$T/tok/slack-bot-token-demo-app"; post BRIEFING_CHANNEL=reports BRIEFING_NO_POST=1 -- 'a dry run'; chmod 600 "$T/tok/slack-bot-token-demo-app"
[ "$OUT" = "not posted (BRIEFING_NO_POST)" ] && [ "$(nreq)" = 0 ] && grep -q '^a dry run$' "$T/blog/would-post.log" && [ -z "$(logline)" ] \
    && ok "BRIEFING_NO_POST: the text goes to would-post.log, nothing is sent, no log line (the token file was not touched)" || bad "no post: out=$OUT requests=$(nreq) log=[$(logline)]"

# ---- reply.sh: through the reports channel's webhook, into the thread, with or without the app's token
fresh; OUT=$(env -u SALA_NOTIFY_CHANNEL -u BRIEFING_CHANNEL "$D/reply.sh" 1760000000.123456 'Done' 2>&1); h=$(hookreq); printf '%s\n' "$OUT" >> "$T/all.out"
[ "$OUT" = ok ] && [ "$(napi)" = 0 ] && [ "$(nhook)" = 1 ] && [ "$(cat "$T/req/$h.path")" = /hook-reports ] && [ -z "$(logline)" ] \
    && body_eq "$T/req/$h.body" '{"text":"Done","thread_ts":"1760000000.123456","unfurl_links":false,"unfurl_media":false}' \
    && ok "reply.sh: the thread reply goes through the reports webhook with its thread_ts, not through the app, no log line" || bad "reply.sh: out=$OUT apis=$(napi) hooks=$(nhook) log=[$(logline)] $(cat "$T/req/$h.body" 2>/dev/null)"
fresh; rm -f "$T/tok/slack-bot-token-demo-app"; OUT=$(env -u SALA_NOTIFY_CHANNEL -u BRIEFING_CHANNEL "$D/reply.sh" 1760000000.123456 'Done' 2>&1); h=$(hookreq)
[ "$OUT" = ok ] && [ "$(nhook)" = 1 ] && [ "$(napi)" = 0 ] && [ "$(cat "$T/req/$h.path")" = /hook-reports ] && [ -z "$(logline)" ] \
    && ok "reply.sh without the token: the same webhook post, and no log line (a thread reply is not a failed bot post)" || bad "reply.sh no token: out=$OUT hooks=$(nhook) log=[$(logline)]"
mk_token demo-app 600 "$TOKEN"$'\n'

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
exit $fail
