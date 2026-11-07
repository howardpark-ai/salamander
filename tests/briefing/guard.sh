#!/usr/bin/env bash
# lib.sh's delivery guard: run_claude counts the Workspace tool calls in the stream log (GMAIL_CALLS) and deliver posts
# the digest only when that count is non-zero (else the 🚨 "held back" notice), and a loud notice instead of the digest
# for the auth sentinel, an empty result or a non-zero exit. A fake `claude` writes the stream log; post_slack is stubbed
# to a file, and the real post_slack is pointed at a listener on 127.0.0.1 for the payload Slack accepts, its linker at no
# sessions, board or repos. Nothing leaves the box and the real webhook is never read. (wording checks dropped.)
set -u
export BRIEFING_GMAIL_CONNECTOR=demo   # a made-up connector word (config.example): the tools are mcp__claude_ai_Google_Workspace_demo__* and the portal's gdemo_*
ROOT=$(cd "$(dirname "$0")/../.." && pwd); D=$ROOT/contrib/briefing
fail=0; ok() { echo "  ok   $*"; }; bad() { echo "  FAIL $*"; fail=1; }
export BRIEFING_BACKEND=cli   # the `claude -p` path under test; the Agent SDK window is tests/briefing/sdk.sh's
T=$(mktemp -d); trap 'kill "${SRV:-}" 2>/dev/null; rm -rf "$T"' EXIT
export BRIEFING_LOGDIR="$T/logs"   # unset, lib.sh would migrate the real old ~/.cache directory
mkdir -p "$T/home" "$T/bin" "$T/logs"
cat > "$T/bin/claude" <<'FAKE'
#!/usr/bin/env bash
# fake claude: FAKE_CALLS Workspace tool calls, then FAKE_RESULT as the result line; exits FAKE_RC
python3 - <<'PY'
import json, os
n = int(os.environ.get("FAKE_CALLS", "0"))
print(json.dumps({"type": "system", "subtype": "init"}, separators=(",", ":")))
for i in range(n):
    print(json.dumps({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": f"t{i}",
        "name": "mcp__claude_ai_Google_Workspace_demo__search_gmail_messages", "input": {"query": "newer_than:1d"}}]}},
        separators=(",", ":")))
print(json.dumps({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "x",
    "name": "mcp__claude_ai_Slack__slack_read_channel", "input": {}}]}}, separators=(",", ":")))
print(json.dumps({"type": "result", "result": os.environ.get("FAKE_RESULT", "")}, separators=(",", ":")))
PY
exit "${FAKE_RC:-0}"
FAKE
chmod +x "$T/bin/claude"
printf 'http://127.0.0.1:9/never\n' > "$T/webhook"   # a dead local port: a missed stub fails here, not at Slack

# case <label> <calls> <rc> <result>: source lib.sh in a fresh bash, repoint its paths, stub posting, run and deliver.
# Prints GMAIL_CALLS, deliver's status and every post, one per line block.
case_run() {
    HOME="$T/home" FAKE_CALLS=$2 FAKE_RC=$3 FAKE_RESULT=$4 bash -c '
        . "$1/lib.sh" 2>/dev/null
        HOME=$2/home LOGDIR=$2/logs CLAUDE_BIN=$2/bin/claude WEBHOOK_FILE=$2/webhook
        POSTS=$2/posts; post_slack() { printf "POST<<%s>>\n" "$1" >> "$POSTS"; }
        run_claude "guard-$3" "a prompt"
        echo "calls=$GMAIL_CALLS rc=$RC"
        deliver "guard-$3" "Morning Email Summary"; echo "deliver=$?"
    ' _ "$D" "$T" "$1"
}
expect() { # expect <label> <output> <posts> <pattern-in-output> <pattern-in-posts> [<pattern not in posts>]
    printf '%s\n' "$2" | grep -q -- "$4" && ok "$1: $4" || bad "$1: want '$4' in: $2"
    printf '%s\n' "$3" | grep -q -- "$5" && ok "$1: posted $5" || bad "$1: want post '$5', got: $3"
    [ -z "${6:-}" ] || { printf '%s\n' "$3" | grep -q -- "$6" && bad "$1: posted '$6' anyway" || ok "$1: did not post '$6'"; }
}
DIGEST=$'*Morning Email Summary*\n• one real line from Gmail'

rm -f "$T/posts"; out=$(case_run zero 0 0 "$DIGEST"); posts=$(cat "$T/posts" 2>/dev/null)
expect "0 Workspace calls" "$out" "$posts" "calls=0 rc=0" "held back" "one real line from Gmail"
printf '%s\n' "$out" | grep -qx 'deliver=1' && ok "0 Workspace calls: deliver returns 1" || bad "0 Workspace calls: $out"

rm -f "$T/posts"; out=$(case_run two 2 0 "$DIGEST"); posts=$(cat "$T/posts" 2>/dev/null)
expect "2 Workspace calls" "$out" "$posts" "calls=2 rc=0" "one real line from Gmail" "held back"
printf '%s\n' "$out" | grep -qx 'deliver=0' && ok "2 Workspace calls: deliver returns 0" || bad "2 Workspace calls: $out"

rm -f "$T/posts"; out=$(case_run empty 3 0 ""); posts=$(cat "$T/posts" 2>/dev/null)
expect "empty result" "$out" "$posts" "deliver=1" "failed"

rm -f "$T/posts"; out=$(case_run crash 3 1 "$DIGEST"); posts=$(cat "$T/posts" 2>/dev/null)
expect "claude exit 1" "$out" "$posts" "calls=3 rc=1" "ended with an error" "one real line from Gmail"

rm -f "$T/posts"; out=$(case_run auth 1 0 "Google Workspace demo connector needs re-authorization."); posts=$(cat "$T/posts" 2>/dev/null)
expect "auth sentinel" "$out" "$posts" "deliver=1" "didn't run"

# the real post_slack, against a listener on 127.0.0.1: the JSON shape
PORT_FILE=$T/port
python3 - "$PORT_FILE" "$T/body" <<'PY' &
import http.server, sys
port_file, body_file = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        data = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        open(body_file, "wb").write(data)
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(port_file, "w").write(str(s.server_address[1]))
s.handle_request()
PY
SRV=$!
for _ in $(seq 50); do [ -s "$PORT_FILE" ] && break; sleep 0.1; done
if [ -s "$PORT_FILE" ]; then
    printf 'http://127.0.0.1:%s/hook\n' "$(cat "$PORT_FILE")" > "$T/webhook"
    resp=$(HOME="$T/home" BRIEFING_SESSIONS_CMD=true BRIEFING_BOARD_DIR= BRIEFING_COMMIT_REPOS= bash -c '. "$1/lib.sh" 2>/dev/null; WEBHOOK_FILE=$2/webhook; post_slack "plain text"' _ "$D" "$T" 2>&1)
    wait "$SRV" 2>/dev/null; SRV=
    [ "$resp" = ok ] && ok "post_slack: listener answered" || bad "post_slack response: $resp"
    python3 - "$T/body" <<'PY' && ok "post_slack: the JSON payload Slack accepts (text, unfurls off)" || bad "post_slack body: $(cat "$T/body" 2>/dev/null)"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d == {"text": "plain text", "unfurl_links": False, "unfurl_media": False}, d
PY
else
    bad "the 127.0.0.1 listener did not start"
fi
exit $fail
