#!/usr/bin/env bash
# The lane sign-in watch (lib/watch.sh, SIGN-IN WATCH): a /login typed in one pane re-signed its
# whole lane, and the lane sat on another account unnoticed. The watch asks each login lane's directory what it is signed in to
# (`claude auth status --json`) and the api lane's key whether the Messages API accepts it, against the table in common.sh
# (lane_expect), and posts once per change. The fake `claude` here is a script answering `auth status --json` from
# <config dir>/auth.json in the shapes the CLI prints (signed in: loggedIn true, authMethod
# "claude.ai", orgName, subscriptionType, exit 0; signed out: loggedIn false, authMethod "none", exit 1; email and ids are
# placeholders), logging every call with its CLAUDE_CONFIG_DIR and whether a key or token was in its environment (never a
# value). The API is a local http server (python3) answering with the status code in a file and logging each request's model,
# max_tokens, whether the x-api-key equalled the dummy key file's value and whether the workspace header matched (counted, not
# printed). Slack is a file (SALA_NOTIFY_CMD). Checked: every lane right → silent, the subscription-1 look with no key or token in the
# CLI's environment though the watch's own has one, one API request with the key and the
# workspace id from the files, haiku and max_tokens 1, the model the newest haiku a GET /v1/models lists (the stub serves it
# and the POST log records the model named: newest created_at over list order, a non-haiku ignored, the first on a tie, an
# explicit SALA_SIGNIN_API_MODEL with no listing, a failed listing — 500, bad JSON, no haiku, a dropped connection — the pin
# with the verdict unchanged, a 503 listing leaving it to the POST, a 401/403 listing the key refused with no POST); the logins and the key not asked again inside their intervals; the
# team directory re-signed onto a Max login → exactly one post naming the lane, what was expected and seen, the fix with the
# lane's directory and the warning against /login, no email in it, a second tick silent; another wrong state → one more post;
# an unreadable answer → silent and the earlier alert kept; right again → one lifted post, then silent; subscription-1 signed out and
# back; the key refused (401) → one post, a 400 (the credit) → the key counts as working, a
# 429 and no network → silent and the alert kept, 200 → lifted; no key file → silent while nobody is on the lane, an alert once
# a session is, lifted when the file is back; two lanes breaking in one tick → one post; the knob off → nothing asked or
# kept; a plain `watch` tick runs the step; no key value, email or alarming word in any post, log or state.
# Usage: bash tests/signin.sh   (exit 0 = pass; ~15 s)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_TZ CLAUDE_CONFIG_DIR ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_CUSTOM_HEADERS CLAUDE_CODE_OAUTH_TOKEN
unset SALA_LANE_API_KEY_FILE SALA_LANE_API_WORKSPACE_FILE SALA_LANE_TEAM_DIR SALA_MASTER SALA_CLAUDE SALA_SIGNIN_ALERT
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
export SALA_SIGNIN_ALERT=on   # lib.sh turns the step off for every other suite (their fake does not answer `auth status`); this is its suite
export SALA_LANE_TEAM_ORG=Example-Org   # the team lane's expected org is a setting with no default (empty = any org): a made-up one here
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null
TEAM="$HOME/.claude-team"
mkdir -p "$HOME/.claude" "$TEAM" "$HOME/.local/bin" "$HOME/.config/anthropic"
export PATH="$HOME/.local/bin:$PATH"
POSTS="$HOME/posts.txt"; export SALA_NOTIFY_CMD="cat >> $POSTS"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_LIMIT_ALERT=off SALA_LIMIT_RESUME=off SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off
export SALA_SIGNIN_EVERY=0 SALA_SIGNIN_API_EVERY=0   # every tick looks (the intervals have their own checks)
# the plain `watch` tick below runs the whole tick with no master (nothing is kept alive, everything else runs), so
# the suite has a private tmux server of its own with one throwaway session — never the fleet's — and no Remote Control server
SOCK="sala-signin-$$"; unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux
tmux new-session -d -s sala-test-anchor -c "$HOME" "sleep 600"; touch "$HOME/.claude/salamander-rc.stopped"
SALA="$ROOT/bin/salamander"; WLOG="$HOME/.claude/salamander-watch.log"; STATE="$HOME/.local/state/salamander/lane-signin.state"
CALLS="$HOME/claude.calls"
# the fake claude: `auth status --json` answers from <config dir>/auth.json, exit code from auth.rc (0 when absent); every call
# logged with its argv, its CLAUDE_CONFIG_DIR and whether a key or a token was in its environment
cat > "$HOME/.local/bin/claude" <<EOF
#!/bin/bash
d="\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}"
echo "\$* cfg=\${CLAUDE_CONFIG_DIR:--} key=\$([ -n "\${ANTHROPIC_API_KEY:-}" ] && echo y || echo n) tok=\$([ -n "\${ANTHROPIC_AUTH_TOKEN:-}" ] && echo y || echo n)" >> "$CALLS"
case "\$1 \$2" in "auth status") cat "\$d/auth.json" 2>/dev/null; rc=\$(cat "\$d/auth.rc" 2>/dev/null); exit "\${rc:-0}";; esac
exit 0
EOF
chmod +x "$HOME/.local/bin/claude"
signed_in() {  # <dir> <subscriptionType> <orgName>: the signed-in shape (email and ids are placeholders)
    printf '{\n  "loggedIn": true,\n  "authMethod": "claude.ai",\n  "apiProvider": "firstParty",\n  "analyticsDisabled": false,\n  "projectsDirectory": "%s/projects",\n  "configDirectory": "%s",\n  "email": "someone@example.com",\n  "orgId": "00000000-0000-4000-8000-000000000000",\n  "orgName": "%s",\n  "subscriptionType": "%s"\n}\n' "$1" "$1" "$3" "$2" > "$1/auth.json"; rm -f "$1/auth.rc"; }
signed_out() {  # <dir>: the shape of a directory with no login (the CLI exits 1 with it)
    printf '{\n  "loggedIn": false,\n  "authMethod": "none",\n  "apiProvider": "firstParty",\n  "analyticsDisabled": false,\n  "projectsDirectory": "%s/projects",\n  "configDirectory": "%s"\n}\n' "$1" "$1" > "$1/auth.json"; echo 1 > "$1/auth.rc"; }
broken() { echo "Error: the CLI could not start" > "$1/auth.json"; echo 2 > "$1/auth.rc"; }   # <dir>: no JSON at all
printf '{"fake":true}\n' > "$TEAM/.credentials.json"
# the API: a local server answering POST /v1/messages with the code in api.code, and GET /v1/models with the code in
# models.code (200 when absent; "drop" closes the connection unanswered) and the body in models.json; one log line per
# request, POSTs in api.log with the model they named, GETs in models.log (the key compared, never written)
API_LOG="$HOME/api.log"; API_CODE="$HOME/api.code"; echo 200 > "$API_CODE"
MODELS_LOG="$HOME/models.log"; MODELS_CODE="$HOME/models.code"; MODELS_JSON="$HOME/models.json"
models() {  # <id>=<created_at>…: the listing's body, in the order given (the real API lists newest first)
    local a s=''; for a in "$@"; do s="$s${s:+,}{\"type\":\"model\",\"id\":\"${a%%=*}\",\"display_name\":\"x\",\"created_at\":\"${a#*=}\"}"; done
    printf '{"data":[%s],"has_more":false,"first_id":null,"last_id":null}\n' "$s" > "$MODELS_JSON"; }
models claude-opus-5-5=2026-10-01T00:00:00Z claude-haiku-5-5=2026-10-07T00:00:00Z claude-haiku-4-5-20251001=2025-10-01T00:00:00Z
KEYF="$HOME/.config/anthropic/api-key"; WSF="$HOME/.config/anthropic/workspace-id"; DUMMY="dummy-key-NOT-REAL-$$"; WSID="wsid_dummy_$$"
(umask 077; printf '%s\n' "$DUMMY" > "$KEYF"); printf '%s\n' "$WSID" > "$WSF"
python3 - "$API_LOG" "$API_CODE" "$DUMMY" "$WSID" "$HOME/api.port" "$MODELS_LOG" "$MODELS_CODE" "$MODELS_JSON" <<'PY' &
import json, sys, http.server, socketserver
log, codef, dummy, wsid, portf, mlog, mcodef, mjson = sys.argv[1:9]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        k = self.headers.get("x-api-key"); key = "none" if not k else ("ok" if k == dummy else "bad")
        ws = "y" if self.headers.get("anthropic-workspace-id") == wsid else "n"
        try: code = open(mcodef).read().strip() or "200"
        except OSError: code = "200"
        with open(mlog, "a") as f: f.write("%s path=%s key=%s ws=%s version=%s\n" % (code, self.path, key, ws, self.headers.get("anthropic-version")))
        if code == "drop": self.close_connection = True; return
        code = int(code)
        try: body = open(mjson, "rb").read() if code < 400 else b'{"type":"error","error":{"type":"stub","message":"stub"}}'
        except OSError: body = b"{}"
        self.send_response(code); self.send_header("content-type", "application/json"); self.send_header("content-length", str(len(body))); self.end_headers()
        self.wfile.write(body)
    def do_POST(self):
        n = int(self.headers.get("content-length") or 0); body = self.rfile.read(n)
        try: o = json.loads(body)
        except Exception: o = {}
        k = self.headers.get("x-api-key"); key = "none" if not k else ("ok" if k == dummy else "bad")
        ws = "y" if self.headers.get("anthropic-workspace-id") == wsid else "n"
        try: code = int(open(codef).read().strip() or 200)
        except Exception: code = 500
        with open(log, "a") as f: f.write("%d path=%s model=%s max_tokens=%s key=%s ws=%s version=%s\n" % (code, self.path, o.get("model"), o.get("max_tokens"), key, ws, self.headers.get("anthropic-version")))
        self.send_response(code); self.send_header("content-type", "application/json"); self.end_headers()
        self.wfile.write(b'{"type":"error","error":{"type":"stub","message":"stub"}}' if code >= 400 else b'{"id":"msg_stub","type":"message","content":[]}')
socketserver.TCPServer.allow_reuse_address = True
srv = socketserver.TCPServer(("127.0.0.1", 0), H)
open(portf, "w").write(str(srv.server_address[1])); srv.serve_forever()
PY
API_PID=$!
cleanup() { kill "$API_PID" 2>/dev/null; tmux kill-server 2>/dev/null; tmux_socket_rm; rm -rf "$HOME" 2>/dev/null; true; }; trap cleanup EXIT
waitfor '[ -s "$HOME/api.port" ]' 40 || { echo "  FAIL the API stub did not come up"; exit 1; }
PORT=$(<"$HOME/api.port"); export SALA_SIGNIN_API_URL="http://127.0.0.1:$PORT/v1/messages"
. "$ROOT/lib/common.sh"
sw() { "$SALA" watch --signin >/dev/null 2>&1; }
calls() { local n; n=$(grep -c -- "$1" "$CALLS" 2>/dev/null); echo "${n:-0}"; }
apireqs() { local n; n=$(grep -c . "$API_LOG" 2>/dev/null); echo "${n:-0}"; }
mreqs() { local n; n=$(grep -c . "$MODELS_LOG" 2>/dev/null); echo "${n:-0}"; }
lastmodel() { tail -1 "$API_LOG" 2>/dev/null | sed -n 's/.* model=\([^ ]*\) .*/\1/p'; }   # the model the last POST named
stv() { awk -F= -v k="$1" '$1==k {print substr($0, length(k)+2); exit}' "$STATE" 2>/dev/null; }

echo "== the expected org is a setting: empty (the default) accepts any org"
[ "$(SALA_LANE_TEAM_ORG=Example-Org lane_expect team)" = "team|Example-Org" ] && ok "a set org is what the team lane must report" || bad "set org: $(SALA_LANE_TEAM_ORG=Example-Org lane_expect team)"
[ "$(SALA_LANE_TEAM_ORG= lane_expect team)" = "team|" ] && [ "$(SALA_LANE_MAX_ORG= lane_expect max)" = "max|" ] && ok "an empty org expects none: any org is accepted" || bad "empty org: $(SALA_LANE_TEAM_ORG= lane_expect team)"

echo "== every lane right: silent, and what was asked"
signed_in "$HOME/.claude" max "someone@example.com's Organization"; signed_in "$TEAM" team Example-Org
export ANTHROPIC_API_KEY="dummy-env-key-NOT-REAL-$$"   # the watch run by hand from a pane on the api lane: the key in ITS environment must not reach the CLI
sw; unset ANTHROPIC_API_KEY
[ "$(posts)" = 0 ] && ok "every lane as expected: nothing posted" || bad "posted with every lane right: $(lastpost)"
[ "$(calls 'auth status --json cfg=- key=n tok=n')" = 1 ] && ok "subscription-1: asked once in ~/.claude, no key or token in the CLI's environment" || bad "subscription-1 calls: $(<"$CALLS")"
[ "$(calls "auth status --json cfg=$TEAM key=n tok=n")" = 1 ] && ok "subscription-2: asked once in its directory" || bad "subscription-2 calls: $(<"$CALLS")"
[ "$(apireqs)" = 1 ] && grep -q '^200 path=/v1/messages model=claude-haiku-5-5 max_tokens=1 key=ok ws=y version=2023-06-01$' "$API_LOG" \
    && ok "api: one request, the key and the workspace id from the files, haiku, one token" || bad "api requests: $(slurp "$API_LOG")"
[ "$(mreqs)" = 1 ] && grep -q '^200 path=/v1/models?limit=100 key=ok ws=y version=2023-06-01$' "$MODELS_LOG" \
    && ok "api: one model listing before it, the same key and workspace headers" || bad "model listings: $(slurp "$MODELS_LOG")"
[ "$(stv subscription-1.seen)" = "ok: a Max account" ] && [ "$(stv subscription-2.seen)" = "ok: a Team account (the Example-Org organization)" ] && [ "$(stv api.seen)" = "ok: the key works" ] \
    && ok "state: each lane recorded right" || bad "state: $(<"$STATE")"

echo "== the intervals"
SALA_SIGNIN_API_EVERY=3600 sw; SALA_SIGNIN_API_EVERY=3600 sw
[ "$(apireqs)" = 1 ] && [ "$(mreqs)" = 1 ] && ok "api: not asked again within the hour, the models not listed again" || bad "api asked $(apireqs) times, listed $(mreqs)"
n=$(calls 'auth status'); SALA_SIGNIN_EVERY=3600 sw
[ "$(calls 'auth status')" = "$n" ] && ok "logins: not asked again within SALA_SIGNIN_EVERY" || bad "logins asked again: $(calls 'auth status') vs $n"

echo "== the team directory re-signed onto a Max login"
signed_in "$TEAM" max "someone@example.com's Organization"
sw; p=$(lastpost)
[ "$(posts)" = 1 ] && ok "one post" || bad "$(posts) posts"
has "$p" "The Team lane is signed in to the wrong account" && ok "headline names the lane" || bad "headline: $(head -1 <<< "$p")"
has "$p" "Team lane: expected a Team account (the Example-Org organization); seen: a Max account (a personal organization), since " && ok "expected and seen, in words" || bad "post: $p"
has "$p" "CLAUDE_CONFIG_DIR=$TEAM claude auth login --claudeai" && has "$p" "never /login inside a pane" && has "$p" "sala lane <lane> <session>" && ok "the fix: the lane's directory, no /login, sala lane for one pane" || bad "fix: $p"
! has "$p" "@" && ok "no email in the post" || bad "an email in the post: $p"
sw; sw
[ "$(posts)" = 1 ] && ok "the next ticks: silent" || bad "$(posts) posts after two more ticks"
[ "$(stv subscription-2.alerted)" = "a Max account (a personal organization)" ] && ok "state: the alert remembered" || bad "state: $(<"$STATE")"

echo "== another wrong state, then unreadable, then right again"
signed_in "$TEAM" team OtherCo; sw
[ "$(posts)" = 2 ] && has "$(lastpost)" "seen: a Team account (the OtherCo organization)" && ok "a different wrong state: one more post" || bad "$(posts) posts: $(lastpost)"
sw; [ "$(posts)" = 2 ] && ok "then silent" || bad "$(posts) posts"
broken "$TEAM"; sw; sw
[ "$(posts)" = 2 ] && ok "no JSON from the CLI: nothing posted, nothing lifted" || bad "$(posts) posts: $(lastpost)"
[ "$(stv subscription-2.alerted)" = "a Team account (the OtherCo organization)" ] && [ "$(stv subscription-2.seen)" = "wrong: a Team account (the OtherCo organization)" ] && ok "unknown: the state kept" || bad "state: $(<"$STATE")"
[ "$(grep -c 'signin: subscription-2 lane: claude auth status gave no answer' "$WLOG")" = 1 ] && ok "unknown: logged once, not on every tick" || bad "unknown log lines: $(grep -c 'gave no answer' "$WLOG")"
signed_in "$TEAM" team Example-Org; sw; p=$(lastpost)
[ "$(posts)" = 3 ] && has "$p" "The Team lane is signed in correctly again" && has "$p" "Team lane: a Team account (the Example-Org organization), as expected, since " && ok "right again: one lifted post" || bad "$(posts) posts: $p"
sw; [ "$(posts)" = 3 ] && [ -z "$(stv subscription-2.alerted)" ] && ok "then silent, the alert cleared" || bad "$(posts) posts; alerted='$(stv subscription-2.alerted)'"

echo "== subscription-1 signed out and back"
signed_out "$HOME/.claude"; sw; p=$(lastpost)
[ "$(posts)" = 4 ] && has "$p" "The Ultra lane is not signed in" && has "$p" "Ultra lane: expected a Max account; seen: not signed in, since " && ok "subscription-1 signed out: one post" || bad "$(posts) posts: $p"
has "$p" 'fix: sign the lane in again in the web UI'"'"'s Shell: `claude auth login --claudeai` (open the link it prints, then paste the code back with Shift+Insert)' && ok "subscription-1: the fix without CLAUDE_CONFIG_DIR" || bad "fix: $p"
signed_in "$HOME/.claude" max "someone@example.com's Organization"; sw
[ "$(posts)" = 5 ] && has "$(lastpost)" "The Ultra lane is signed in correctly again" && ok "subscription-1 back: lifted once" || bad "$(posts) posts: $(lastpost)"

echo "== the api lane's key"
echo 401 > "$API_CODE"; sw; p=$(lastpost)
[ "$(posts)" = 6 ] && has "$p" "The api lane's key does not work" && has "$p" "api lane: expected a key the API accepts; seen: the key is refused (HTTP 401), since " && has "$p" "fix: put a working key in $KEYF" && ok "401: one post with the fix" || bad "$(posts) posts: $p"
sw; [ "$(posts)" = 6 ] && ok "401 again: silent" || bad "$(posts) posts"
echo 400 > "$API_CODE"; sw
[ "$(posts)" = 7 ] && has "$(lastpost)" "The api lane's key works again" && has "$(lastpost)" "api lane: the key works, as expected" && ok "400 (the credit): the key counts as accepted, lifted once" || bad "$(posts) posts: $(lastpost)"
sw; [ "$(posts)" = 7 ] && ok "400 again: silent" || bad "$(posts) posts"
echo 403 > "$API_CODE"; sw
[ "$(posts)" = 8 ] && has "$(lastpost)" "the key is refused (HTTP 403)" && ok "403: a new episode, one post" || bad "$(posts) posts: $(lastpost)"
echo 429 > "$API_CODE"; sw; sw
[ "$(posts)" = 8 ] && [ "$(stv api.alerted)" = "the key is refused (HTTP 403)" ] && ok "429: silent, the alert kept" || bad "$(posts) posts, alerted='$(stv api.alerted)'"
echo 503 > "$API_CODE"; sw
[ "$(posts)" = 8 ] && ok "503: silent" || bad "$(posts) posts"
SALA_SIGNIN_API_URL="http://127.0.0.1:1/v1/messages" sw
[ "$(posts)" = 8 ] && [ "$(stv api.alerted)" = "the key is refused (HTTP 403)" ] && grep -q 'signin: api lane: no answer from the API' "$WLOG" && ok "no network: silent, the alert kept, logged" || bad "$(posts) posts: $(tail -3 "$WLOG")"
echo 200 > "$API_CODE"; sw
[ "$(posts)" = 9 ] && has "$(lastpost)" "The api lane's key works again" && ok "200: lifted once" || bad "$(posts) posts: $(lastpost)"
n=$(apireqs)

echo "== no key file"
mv "$KEYF" "$KEYF.away"; sw; sw
[ "$(posts)" = 9 ] && [ "$(apireqs)" = "$n" ] && ok "no file and nobody on the lane: not watched, nothing asked" || bad "$(posts) posts, $(apireqs) requests"
mkdir -p "$SALA_STATE_DIR"; printf 'sala-test-x\tapi\n' > "$SALA_LANES"; sw; p=$(lastpost)
[ "$(posts)" = 10 ] && has "$p" "api lane: expected a key the API accepts; seen: no key file at $KEYF" && [ "$(apireqs)" = "$n" ] && ok "a session on the lane: one post, no request made" || bad "$(posts) posts, $(apireqs) requests: $p"
sw; [ "$(posts)" = 10 ] && ok "then silent" || bad "$(posts) posts"
mv "$KEYF.away" "$KEYF"; sw
[ "$(posts)" = 11 ] && has "$(lastpost)" "The api lane's key works again" && [ "$(apireqs)" = $((n + 1)) ] && ok "the file back: asked at once, lifted once" || bad "$(posts) posts, $(apireqs) requests: $(lastpost)"

echo "== two lanes in one tick, the knob, a plain watch tick"
signed_in "$TEAM" max "someone@example.com's Organization"; echo 401 > "$API_CODE"; sw; p=$(lastpost)
[ "$(posts)" = 12 ] && has "$(head -1 <<< "$p")" "Sign-in changed on the Team and api lanes" && has "$p" "Team lane: expected" && has "$p" "api lane: expected" && ok "two lanes: one post naming both" || bad "$(posts) posts: $p"
signed_in "$TEAM" team Example-Org; echo 200 > "$API_CODE"; sw; p=$(lastpost)
[ "$(posts)" = 13 ] && has "$(head -1 <<< "$p")" "Signed in correctly again: the Team and api lanes" && has "$p" "Team lane: a Team account" && has "$p" "api lane: the key works" && ok "both right: one lifted post" || bad "$(posts) posts: $p"
n=$(calls 'auth status'); m=$(apireqs); l=$(mreqs); signed_out "$HOME/.claude"
SALA_SIGNIN_ALERT=off sw
[ "$(posts)" = 13 ] && [ "$(calls 'auth status')" = "$n" ] && [ "$(apireqs)" = "$m" ] && [ "$(mreqs)" = "$l" ] && [ "$(stv subscription-1.seen)" = "ok: a Max account" ] && ok "the knob off: nothing asked, nothing posted, the state untouched" || bad "knob off: $(posts) posts, calls $(calls 'auth status') vs $n, state $(stv subscription-1.seen)"
"$SALA" watch >/dev/null 2>&1   # no master configured: the tick still runs this step before it ends
[ "$(posts)" = 14 ] && has "$(lastpost)" "The Ultra lane is not signed in" && ok "a plain watch tick runs the step" || bad "$(posts) posts after a plain watch: $(lastpost)"
signed_in "$HOME/.claude" max "someone@example.com's Organization"; sw

echo "== the model: the newest haiku the API lists, the pin only as the fallback"
p0=$(posts)
models claude-haiku-4-5-20251001=2025-10-01T00:00:00Z claude-opus-9-9=2027-06-01T00:00:00Z claude-haiku-6-1=2027-01-15T00:00:00Z claude-haiku-5-5=2026-10-07T00:00:00Z
sw; [ "$(lastmodel)" = claude-haiku-6-1 ] && ok "the newest created_at among the haikus wins over list order; a newer non-haiku is ignored" || bad "model: $(lastmodel)"
models claude-haiku-7-a=2027-03-01T00:00:00Z claude-haiku-7-b=2027-03-01T00:00:00Z claude-haiku-6-1=2027-01-15T00:00:00Z
sw; [ "$(lastmodel)" = claude-haiku-7-a ] && ok "a tie on created_at: the first listed" || bad "tie: $(lastmodel)"
l=$(mreqs); SALA_SIGNIN_API_MODEL=claude-explicit-test sw
[ "$(lastmodel)" = claude-explicit-test ] && [ "$(mreqs)" = "$l" ] && ok "SALA_SIGNIN_API_MODEL set: used as is, no listing made" || bad "explicit: $(lastmodel), listings $(mreqs) vs $l"
echo 500 > "$MODELS_CODE"; sw
[ "$(lastmodel)" = claude-haiku-5-5 ] && [ "$(stv api.seen)" = "ok: the key works" ] && ok "listing 500: the pin, the key still counted as working" || bad "500: $(lastmodel), seen '$(stv api.seen)'"
echo 200 > "$MODELS_CODE"; echo 'not json {' > "$MODELS_JSON"; a=$(apireqs); sw
[ "$(lastmodel)" = claude-haiku-5-5 ] && [ "$(apireqs)" = $((a + 1)) ] && [ "$(stv api.seen)" = "ok: the key works" ] && ok "listing bad JSON: the pin, the request still made" || bad "bad JSON: $(lastmodel), requests $(apireqs) vs $a"
models claude-opus-9-9=2027-06-01T00:00:00Z claude-sonnet-9-9=2027-05-01T00:00:00Z; sw
[ "$(lastmodel)" = claude-haiku-5-5 ] && ok "no haiku listed: the pin" || bad "no haiku: $(lastmodel)"
echo drop > "$MODELS_CODE"; sw
[ "$(lastmodel)" = claude-haiku-5-5 ] && [ "$(stv api.seen)" = "ok: the key works" ] && ok "listing connection dropped: the pin, the key still counted as working" || bad "drop: $(lastmodel), seen '$(stv api.seen)'"
[ "$(posts)" = "$p0" ] && ok "listing failures: nothing posted" || bad "$(posts) posts vs $p0: $(lastpost)"
echo 503 > "$MODELS_CODE"; echo 401 > "$API_CODE"; sw; p=$(lastpost)
[ "$(lastmodel)" = claude-haiku-5-5 ] && [ "$(posts)" = $((p0 + 1)) ] && has "$p" "seen: the key is refused (HTTP 401)" && ok "listing 503: the pin, the request decides (its 401 posted)" || bad "503+401: $(lastmodel), $(posts) posts: $p"
echo 200 > "$API_CODE"; rm -f "$MODELS_CODE"; models claude-haiku-6-1=2027-01-15T00:00:00Z; sw
[ "$(lastmodel)" = claude-haiku-6-1 ] && [ "$(posts)" = $((p0 + 2)) ] && has "$(lastpost)" "The api lane's key works again" && ok "listing back: the newest haiku, lifted once" || bad "back: $(lastmodel), $(posts) posts"
echo 401 > "$MODELS_CODE"; a=$(apireqs); sw; p=$(lastpost)
[ "$(apireqs)" = "$a" ] && [ "$(posts)" = $((p0 + 3)) ] && has "$p" "seen: the key is refused (HTTP 401), since " && ok "listing 401: the key refused, one post, no request made" || bad "listing 401: requests $(apireqs) vs $a, $(posts) posts: $p"
echo 403 > "$MODELS_CODE"; sw; p=$(lastpost)
[ "$(apireqs)" = "$a" ] && [ "$(posts)" = $((p0 + 4)) ] && has "$p" "the key is refused (HTTP 403)" && ok "listing 403: the key refused, no request made" || bad "listing 403: requests $(apireqs) vs $a, $(posts) posts: $p"
rm -f "$MODELS_CODE"; out=$("$SALA" watch --signin 2>&1)
[ "$(posts)" = $((p0 + 5)) ] && has "$(lastpost)" "The api lane's key works again" && ok "listing right again: lifted once" || bad "$(posts) posts: $(lastpost)"
! grep -qF -- "$DUMMY" <<< "$out" && ! grep -qF -- "$DUMMY" "$API_LOG" "$MODELS_LOG" && ok "the key's value is in neither the watch's output nor the stub's logs" || bad "the key's value in the output or a stub log"

echo "== nothing sensitive or alarming anywhere"
! grep -qF -- "$DUMMY" "$POSTS" "$WLOG" "$CALLS" "$STATE" && ok "the key's value is in no post, log, call or state" || bad "the key's value leaked"
! grep -q '@' "$POSTS" && ok "no email in any post" || bad "an email in a post: $(grep '@' "$POSTS")"
! grep -qiE 'leak|breach|kill|quota|credential' "$POSTS" && ok "no alarming word in any post" || bad "alarming word: $(grep -iE 'leak|breach|kill|quota|credential' "$POSTS")"
! grep -qE '^[^ ].*[|]' "$POSTS" && ok "no state separator in a headline" || bad "$(grep -E '^[^ ].*[|]' "$POSTS")"

[ "$fail" = 0 ] && echo "signin: pass" || echo "signin: FAIL"
exit $fail
