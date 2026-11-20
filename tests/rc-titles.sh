#!/usr/bin/env bash
# tests/rc-titles.sh — `sala rc --titles` (lib/rc.sh): the claude.ai title of each live bridged pane against its sala name, and setting it.
# The claude.ai API is a tiny local http server (python3, 127.0.0.1, a random port, SALA_ANTHROPIC_API) that holds a list of sessions in a
# file, answers GET /v1/code/sessions and PUT /v1/code/sessions/<id> (title only), and logs every request; the login file is a made-up
# one in the test HOME. Nothing reaches the network, no real credentials or ids exist. The "panes" are `sleep` processes (killed by pid
# at the end) with a registry row each in the test HOME.
#   dry run    lists only the panes whose title differs (name, title, status), one that cannot be set says why, a pane whose session is not
#              in the list is "not listed (N)", exit 0, no PUT; --only narrows it; all matching says "all N bridged panes carry their sala name"
#   apply      --only NAME: one PUT with the body {"title": NAME} and nothing else, the other titles untouched, re-read and `ok`; run again =
#              no PUT (idempotent); two --only names; --apply alone refused (needs --all) before any request; --all sets every differing
#              pane it can and skips the others; a name outside [a-z0-9-] or a nameSource other than user is refused; an unknown name fails
#   errors     a non-200 is its status and the first 200 characters of the answer, a too-long title is the API's own error text (no crash),
#              an unreachable API and a missing login file are one line each, never a traceback
#   secrecy    the token is in no output of any case (the stub echoes it in an error body, which is scrubbed), and it reached the API as the
#              Authorization bearer with the version and platform headers
# Usage: bash tests/rc-titles.sh   (exit 0 = pass; a few seconds)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
. "$ROOT/tests/lib.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/sala-rc-titles.XXXXXX")
exec 8< "$T"; flock -n 8 2>/dev/null   # systemd-tmpfiles' ageing skips a directory held with flock
SRV_PID=""; PIDS=()
cleanup() {
    local p
    for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
    [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; wait 2>/dev/null; exec 8<&-; rm -rf "$T"
}
trap cleanup EXIT
export HOME=$T/home SALA_CONFIG=/dev/null XDG_STATE_HOME=$T/state SALA_STATE_DIR=$T/state/salamander TMPDIR=$T/tmp SALA_LOG_DIR=$T/log
unset XDG_CONFIG_HOME SALA_ANTHROPIC_API
mkdir -p "$HOME/.claude/sessions" "$T/tmp" "$T/ctl" "$T/log"
CTL=$T/ctl; LOG=$CTL/log; SESS=$CTL/sessions.json
TOKEN=example-token-not-a-real-secret-0001
printf '{"claudeAiOauth":{"accessToken":"%s"}}\n' "$TOKEN" > "$HOME/.claude/.credentials.json"; chmod 600 "$HOME/.claude/.credentials.json"
printf '%s' "$TOKEN" > "$CTL/token"

cat > "$T/fake-api.py" <<'PY'
import json, sys, http.server
ctl = sys.argv[1]
good = open(ctl + "/token").read().strip()
def load(): return json.load(open(ctl + "/sessions.json"))
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, status, obj):
        data = (obj if isinstance(obj, str) else json.dumps(obj)).encode()
        self.send_response(status); self.send_header("content-type", "application/json"); self.send_header("content-length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def note(self, body):
        with open(ctl + "/log", "a") as f:
            f.write(json.dumps({"method": self.command, "path": self.path, "auth": self.headers.get("authorization", ""),
                                "version": self.headers.get("anthropic-version"), "platform": self.headers.get("anthropic-client-platform"), "body": body}) + "\n")
    def do_GET(self):
        self.note(None)
        if self.headers.get("authorization", "") != "Bearer " + good: return self.reply(401, {"error": "bad token"})
        if self.path.split("?")[0] == "/v1/code/sessions": return self.reply(200, {"data": load(), "has_more": False})
        self.reply(404, {"error": "no such path"})
    def do_PUT(self):
        n = int(self.headers.get("content-length") or 0); raw = self.rfile.read(n)
        try: body = json.loads(raw.decode("utf-8"))
        except Exception: body = None
        self.note(body)
        if self.headers.get("authorization", "") != "Bearer " + good: return self.reply(401, {"error": "bad token"})
        sid = self.path.rsplit("/", 1)[-1]
        try: failing = open(ctl + "/failput").read().split()
        except OSError: failing = []
        if sid in failing:  # an error body that echoes the credentials back, longer than 200 characters
            return self.reply(500, "upstream error, Authorization: Bearer " + good + " " + "x" * 400)
        rows = load(); row = next((r for r in rows if r["id"] == sid), None)
        if row is None: return self.reply(404, {"error": "no such session"})
        if not isinstance(body, dict) or set(body) != {"title"}: return self.reply(400, {"error": "expected only a title"})
        if len(body["title"]) > 100: return self.reply(400, {"error": "title too long: at most 100 characters"})
        row["title"] = body["title"]; json.dump(rows, open(ctl + "/sessions.json", "w"))
        self.reply(200, {"id": sid, "title": row["title"]})
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(ctl + "/port", "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
python3 -I "$T/fake-api.py" "$CTL" &
SRV_PID=$!
echo '[]' > "$SESS"
waitfor '[ -s "$CTL/port" ]' 40 || { echo "  FAIL the fake API did not come up"; exit 1; }
export SALA_ANTHROPIC_API="http://127.0.0.1:$(<"$CTL/port")"

# -- the panes: a live process and a registry row each (name, nameSource, bridge) ---------------------------------------------------------------
LONG=$(printf 'a%.0s' $(seq 1 120))
pane() {   # <name> <nameSource> <bridge id>
    sleep 600 & local pid=$!; PIDS+=("$pid")
    printf '{"pid":%s,"sessionId":"sid-%s","name":"%s","nameSource":"%s","tmux":"%s:@1.%%1","cwd":"/","bridgeSessionId":"%s","version":"9.9.9"}\n' "$pid" "$1" "$1" "$2" "$1" "$3" > "$HOME/.claude/sessions/$pid.json"
}
pane sf-example-a user session_e1      # title differs
pane sf-example-b user session_e2      # title matches
pane sf-example-c user session_e3      # title differs (its PUT fails in one case)
pane sf-example-d auto session_e4      # title differs, nameSource auto: cannot be set
pane sf-example-e user session_e5      # its session is not in the list
pane Sf-Example-F user session_e6      # title differs, an uppercase name: cannot be set
pane "$LONG" user session_e7           # title differs, a name the API refuses
# an RC server's child (--sdk-url) and a row with no tmux session are not panes
python3 -c "import time; time.sleep(600)" --sdk-url x & P=$!; PIDS+=("$P")
printf '{"pid":%s,"sessionId":"sid-child","name":"sf-example-child","nameSource":"user","tmux":"rc:@1.%%1","bridgeSessionId":"session_e8"}\n' "$P" > "$HOME/.claude/sessions/$P.json"
sleep 600 & P=$!; PIDS+=("$P")
printf '{"pid":%s,"sessionId":"sid-bare","name":"sf-example-bare","nameSource":"user","bridgeSessionId":"session_e9"}\n' "$P" > "$HOME/.claude/sessions/$P.json"

seed() {   # the cloud's state: a, c, d, F, the long one differ; b matches; e is absent; the child and the bare row are listed but are no panes
    python3 - "$SESS" "$LONG" <<'PY'
import json, sys
rows = [("cse_e1", "swift-jaunty-charm"), ("cse_e2", "sf-example-b"), ("cse_e3", "swift-quiet-otter"), ("cse_e4", "auto-title-d"),
        ("cse_e6", "auto-title-f"), ("cse_e7", "auto-title-long"), ("cse_e8", "child-title"), ("cse_e9", "bare-title")]
json.dump([{"id": i, "title": t, "status": "active", "connection_status": "connected"} for i, t in rows], open(sys.argv[1], "w"))
PY
    : > "$LOG"; rm -f "$CTL/failput"
}
title_of() { python3 -I -c 'import json,sys; print(next(r["title"] for r in json.load(open(sys.argv[1])) if r["id"]==sys.argv[2]))' "$SESS" "$1"; }
nreq() { local n; n=$(grep -c "\"method\": \"$1\"" "$LOG" 2>/dev/null); echo "${n:-0}"; }   # <METHOD>: requests the stub saw
AUDIT=$T/audit; : > "$AUDIT"
run() { OUT=$(bash "$ROOT/bin/salamander" rc "$@" 2>"$T/err"); RC=$?; ERR=$(<"$T/err"); printf '%s\n%s\n' "$OUT" "$ERR" >> "$AUDIT"; }   # <rc args…>

echo "== dry run: only the panes whose title differs, read-only, exit 0"
seed; run --titles
[ "$RC" = 0 ] && [ -z "$ERR" ] && ok "exit 0, nothing on stderr" || bad "dry run: rc=$RC err=[$ERR]"
has "$OUT" "NAME" && has "$OUT" "CLAUDE.AI TITLE" && has "$OUT" "STATUS" && ok "a table with NAME, claude.ai title and status" || bad "header: $OUT"
for n in sf-example-a sf-example-c sf-example-d Sf-Example-F; do grep -q "^$n .*" <<< "$OUT" || bad "dry run does not list $n: $OUT"; done
has "$OUT" "swift-jaunty-charm" && has "$OUT" "active/connected" && ok "the differing panes are listed with their title and status" || bad "rows: $OUT"
! grep -q "^sf-example-b " <<< "$OUT" && ! has "$OUT" "sf-example-child" && ! has "$OUT" "sf-example-bare" && ok "a matching pane, an RC child and a row with no tmux session are not listed" || bad "extra rows: $OUT"
has "$OUT" "cannot be set: its nameSource is auto, not user" && has "$OUT" "cannot be set: its name is not in [a-z0-9-]" && ok "a pane that cannot be set says why" || bad "reasons: $OUT"
has "$OUT" "not listed (1): sf-example-e" && ok "a pane whose session is not in the list: not listed (1), not guessed" || bad "not listed: $OUT"
[ "$(nreq PUT)" = 0 ] && [ "$(nreq GET)" = 1 ] && ok "read-only: one GET of the list, no PUT" || bad "requests: $(cat "$LOG")"
[ "$(python3 -I -c 'import json,sys; r=[json.loads(l) for l in open(sys.argv[1])][0]; print(r["path"], r["auth"], r["version"], r["platform"])' "$LOG")" = "/v1/code/sessions?limit=100 Bearer $TOKEN 2023-06-01 cli" ] && ok "the list call: limit 100, the login's bearer, the version and platform headers" || bad "list call: $(head -1 "$LOG" | sed "s/$TOKEN/<TOKEN>/")"
[ "$(title_of cse_e1)" = swift-jaunty-charm ] && ok "no title changed" || bad "a title changed in a dry run"

echo "== dry run with --only, and with --dry-run spelled out"
run --titles --only sf-example-a
[ "$RC" = 0 ] && grep -q "^sf-example-a " <<< "$OUT" && ! grep -q "^sf-example-c " <<< "$OUT" && ok "--only narrows the list to that pane" || bad "--only dry run: rc=$RC $OUT"
run --titles --dry-run
[ "$RC" = 0 ] && grep -q "^sf-example-c " <<< "$OUT" && [ "$(nreq PUT)" = 0 ] && ok "--dry-run is the default spelled out" || bad "--dry-run: rc=$RC $OUT"

echo "== nothing differs: the all-match message, exit 0"
python3 -I - "$SESS" "$LONG" <<'PY'
import json, sys
names = {"cse_e1": "sf-example-a", "cse_e3": "sf-example-c", "cse_e4": "sf-example-d", "cse_e6": "Sf-Example-F", "cse_e7": sys.argv[2]}
rows = json.load(open(sys.argv[1]))
for r in rows:
    if r["id"] in names: r["title"] = names[r["id"]]
json.dump(rows, open(sys.argv[1], "w"))
PY
run --titles
[ "$RC" = 0 ] && [ "$(head -1 <<< "$OUT")" = "all 6 bridged panes carry their sala name" ] && has "$OUT" "not listed (1): sf-example-e" && ok "all 6 bridged panes carry their sala name (the unlisted one still reported)" || bad "all-match: rc=$RC $OUT"

echo "== apply --only: one PUT, the body is the title and nothing else, the others untouched, re-read"
seed; run --titles --apply --only sf-example-a
[ "$RC" = 0 ] && [ "$(nreq PUT)" = 1 ] && ok "exit 0, one PUT" || bad "apply: rc=$RC out=$OUT log=$(cat "$LOG" | sed "s/$TOKEN/<TOKEN>/")"
[ "$(python3 -I -c 'import json,sys; r=[json.loads(l) for l in open(sys.argv[1]) if "\"PUT\"" in l][0]; print(r["path"], json.dumps(r["body"], sort_keys=True), r["auth"] == "Bearer " + sys.argv[2])' "$LOG" "$TOKEN")" = '/v1/code/sessions/cse_e1 {"title": "sf-example-a"} True' ] && ok "PUT /v1/code/sessions/cse_e1 with {\"title\": \"sf-example-a\"} and the bearer" || bad "PUT: $(grep PUT "$LOG" | sed "s/$TOKEN/<TOKEN>/")"
[ "$(title_of cse_e1)" = sf-example-a ] && [ "$(title_of cse_e3)" = swift-quiet-otter ] && [ "$(title_of cse_e4)" = auto-title-d ] && ok "that title changed, no other" || bad "titles: $(title_of cse_e1) $(title_of cse_e3)"
[ "$(head -1 <<< "$OUT")" = "ok      sf-example-a  title set" ] && ok "reported ok after the re-read" || bad "report: $OUT"
[ "$(nreq GET)" = 2 ] && ok "the list is read before and again after the PUT" || bad "GETs: $(nreq GET)"
: > "$LOG"; run --titles --apply --only sf-example-a
[ "$RC" = 0 ] && has "$OUT" "already carries its name" && [ "$(nreq PUT)" = 0 ] && ok "idempotent: run again, ok, no PUT" || bad "again: rc=$RC $OUT"

echo "== apply --only twice names two panes; an unknown name and a pane that cannot be set fail"
seed; run --titles --apply --only sf-example-a --only=sf-example-c
[ "$RC" = 0 ] && [ "$(title_of cse_e1)" = sf-example-a ] && [ "$(title_of cse_e3)" = sf-example-c ] && [ "$(nreq PUT)" = 2 ] && ok "both set, two PUTs" || bad "two --only: rc=$RC $OUT"
seed; run --titles --apply --only sf-example-nope
[ "$RC" = 1 ] && has "$OUT" "FAILED  sf-example-nope  no live bridged pane of that name" && [ "$(nreq PUT)" = 0 ] && ok "an unknown name: FAILED, exit 1, no PUT" || bad "unknown: rc=$RC $OUT"
run --titles --apply --only sf-example-d --only Sf-Example-F
[ "$RC" = 1 ] && has "$OUT" "FAILED  sf-example-d  refused: its nameSource is auto, not user" && has "$OUT" "FAILED  Sf-Example-F  refused: its name is not in [a-z0-9-]" && [ "$(nreq PUT)" = 0 ] && ok "nameSource auto and an uppercase name are refused, no PUT" || bad "refused: rc=$RC $OUT"
run --titles --apply --only sf-example-e
[ "$RC" = 1 ] && has "$OUT" "FAILED  sf-example-e  not listed" && [ "$(nreq PUT)" = 0 ] && ok "a pane whose session is not listed: FAILED (not listed), no PUT" || bad "not listed apply: rc=$RC $OUT"

echo "== apply with no --only is refused; --all applies to every differing pane it can set"
seed; run --titles --apply
[ "$RC" != 0 ] && has "$ERR" "needs --only" && has "$ERR" "--all" && [ ! -s "$LOG" ] && ok "refused with the --all message, before any request" || bad "bare apply: rc=$RC err=[$ERR] log=$(cat "$LOG")"
run --titles --all
[ "$RC" != 0 ] && has "$ERR" "--all needs --apply" && [ ! -s "$LOG" ] && ok "--all without --apply is refused too" || bad "--all alone: rc=$RC err=[$ERR]"
run --titles --apply --all --only sf-example-a
[ "$RC" != 0 ] && [ ! -s "$LOG" ] && ok "--all with --only is refused" || bad "--all --only: rc=$RC err=[$ERR]"
run --titles --apply --all
[ "$RC" = 1 ] && [ "$(title_of cse_e1)" = sf-example-a ] && [ "$(title_of cse_e3)" = sf-example-c ] && ok "--all: the two settable panes changed" || bad "--all titles: rc=$RC $OUT"
has "$OUT" "skip    sf-example-d  its nameSource is auto, not user" && has "$OUT" "skip    Sf-Example-F  its name is not in [a-z0-9-]" && [ "$(title_of cse_e4)" = auto-title-d ] && ok "--all leaves the panes it cannot set, and says so" || bad "--all skips: $OUT"
has "$OUT" "FAILED  $LONG  HTTP 400 " && ok "(the long name's PUT is refused by the API: that one FAILED, so exit 1)" || bad "--all long: $OUT"
[ "$(nreq PUT)" = 3 ] && ok "--all sent three PUTs (a, c, the long name), none for b, d, F" || bad "--all PUTs: $(nreq PUT)"

echo "== errors: a non-200 (status and the first 200 characters, no token), a too-long title, an unreachable API, no login file"
seed; echo cse_e3 > "$CTL/failput"; run --titles --apply --only sf-example-c --only sf-example-a
[ "$RC" = 1 ] && has "$OUT" "FAILED  sf-example-c  HTTP 500 upstream error, Authorization: Bearer <token> " && ok "a 500: FAILED with its status and the answer, the token scrubbed" || bad "500: rc=$RC $OUT"
line=$(grep "^FAILED  sf-example-c" <<< "$OUT"); body=${line#*HTTP 500 }
[ "${#body}" = 200 ] && ok "the answer is cut at 200 characters" || bad "answer length ${#body}"
[ "$(title_of cse_e1)" = sf-example-a ] && has "$OUT" "ok      sf-example-a  title set" && ok "the other pane is still set (one failure does not stop the rest)" || bad "after a 500: $OUT"
seed; run --titles --apply --only "$LONG"
[ "$RC" = 1 ] && has "$OUT" "HTTP 400 {\"error\": \"title too long: at most 100 characters\"}" && ! has "$OUT$ERR" "Traceback" && ok "a title the API refuses: its HTTP error text reported, no crash" || bad "long title: rc=$RC $OUT $ERR"
SALA_ANTHROPIC_API=http://127.0.0.1:1 run --titles
[ "$RC" = 1 ] && has "$OUT" "cannot list claude.ai sessions: HTTP 0" && ! has "$OUT$ERR" "Traceback" && ok "an unreachable API: one line, exit 1, no traceback" || bad "unreachable: rc=$RC $OUT $ERR"
mv "$HOME/.claude/.credentials.json" "$HOME/.claude/.credentials.off"; run --titles
mv "$HOME/.claude/.credentials.off" "$HOME/.claude/.credentials.json"
[ "$RC" = 1 ] && has "$OUT" "no claude.ai login found" && ! has "$OUT$ERR" "Traceback" && ok "no login file: said, exit 1, no traceback" || bad "no login: rc=$RC $OUT $ERR"
run --titles --bogus; [ "$RC" != 0 ] && has "$ERR" "unknown argument '--bogus'" && ok "an unknown argument is refused" || bad "bogus: rc=$RC $ERR"

echo "== secrecy: the token is in no output of any case"
if grep -qF "$TOKEN" "$AUDIT"; then bad "the token is in an output: $(grep -F "$TOKEN" "$AUDIT" | sed "s/$TOKEN/<TOKEN>/g" | head -3)"; else ok "the token is in no stdout or stderr of any case above ($(grep -c . "$AUDIT") lines audited)"; fi
grep -rqF "$TOKEN" "$SALA_STATE_DIR" "$T/log" 2>/dev/null && bad "the token is in a state or log file" || ok "the token is in no state or log file"

echo "rc-titles: $([ $fail = 0 ] && echo pass || echo FAIL)"
exit $fail
