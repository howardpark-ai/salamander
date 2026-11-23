#!/usr/bin/env bash
# sala's own key for stackshot and the pass it trades for (lib/stackshot_key.py, lib/stackshot_form.py, lib/stackshot-key.sh; docs/stackshot-contracts.md interface 37, "A caller's own key").
# Against a stand-in for the server side of the contract (tests/stackshotkey_stub.py: 127.0.0.1, a random port, in memory, the Ed25519 signature checked with `cryptography`, killed
# by its PID at the end) and a stand-in for stackshot's client.py (tests/stackshotkey_client.py: it says whether STACKSHOT_CLIENT_PASS was set, never its value). Nothing here reaches the
# real stackshot, makes a key anywhere but in the suite's own temporary folders, or enrolls anything.
#   the key       `init` makes a 0600 file in a 0700 folder, 32 raw bytes in base64url without padding; a second run and eight at once leave the one key as it was; nothing printed holds it
#   enroll        the body (the 43-character public key, label `sala`, sender `sala`), the printed state / short fingerprint / item / what happens next, a repeat answers the same, an approved key
#   status        none | unknown (not enrolled) | pending | approved, from a signed claim
#   the claim     header {"alg":"EdDSA"}, iss = the SHA-256 of the public bytes, aud = the address without a trailing slash, exp = iat + 55, a jti of 32 or more characters that is new each time, at most 2048 characters
#   the pass      reused until 60 s before it ends (one trade for several calls; a cache that is 30 s from its end trades again), the cache folder 0700 and its file 0600
#   the wrapper   the variable is set for the form's call only; arguments, standard input, exit code, standard output and standard error are the client's own, byte for byte
#   fallbacks     no key, a key still waiting, an unreachable server, a 429 / 500 / 401 answer, the cryptography package missing (simulated), a key file open to others, a stale-looking cache:
#                 the client runs with the machine token and the exit code it gives alone; at most one log line per five minutes says why; SALA_STACKSHOT_PASS=off is silent
#   call sites    common.sh's four form calls (agent_register, rename_list_run, rename_side_run, _retire_call) and bg-agents' default post command go through the wrapper; the sender labels start with `sala-`
#   no secret     the private key and every pass the server issued are looked for in every output, log and argv the suite kept: none is there
# Isolated HOME, XDG folders and log folder in a temporary folder (locked while the suite runs, removed at the end). Needs python3 with `cryptography`; without it a virtual environment is made
# with uv in the temporary folder, and without uv the suite says SKIP.
# Usage: bash tests/stackshotkey.sh   (exit 0 = pass; under a minute)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
T=""; STUB_PID=""
cleanup() {
    [ -n "$STUB_PID" ] && { kill "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null; }   # by its PID, never by name
    [ -n "$T" ] && rm -rf "$T"
}
trap cleanup EXIT
T=$(mktemp -d "${TMPDIR:-/tmp}/sala-sskey.XXXXXX")
exec 8< "$T"; flock -n 8 2>/dev/null   # systemd-tmpfiles' ageing skips a directory held with flock

if ! python3 -c 'import cryptography' 2>/dev/null; then
    if command -v uv >/dev/null 2>&1 && uv venv -q "$T/venv" >/dev/null 2>&1 && uv pip install -q --python "$T/venv/bin/python" cryptography >/dev/null 2>&1; then
        export PATH="$T/venv/bin:$PATH"
    else
        echo "stackshotkey: SKIP (python3 has no cryptography package and uv could not make one)"; exit 0
    fi
fi

export HOME="$T/home" XDG_STATE_HOME="$T/state" XDG_RUNTIME_DIR="$T/run" XDG_CONFIG_HOME="$T/cfg" SALA_LOG_DIR="$T/logs" SALA_STATE_DIR="$T/state/salamander" SALA_CONFIG=/dev/null
mkdir -p "$HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR" "$XDG_CONFIG_HOME" "$SALA_LOG_DIR" "$T/out"; chmod 700 "$XDG_RUNTIME_DIR"
unset SALA_STACKSHOT_PASS SALA_STACKSHOT_KEY_DIR SALA_STACKSHOT_PASS_DIR STACKSHOT_CONFIG BOARD_MCP_CONFIG SALA_STACKSHOT_CLIENT SALA_STACKSHOT_DIR STACKSHOT_CLIENT_PASS
export SALA_STACKSHOT_PASS_BACKOFF=0   # a failed trade is asked again at once here (production: 30 s); the backoff has its own case
KEYF="$XDG_STATE_HOME/salamander/stackshot-key/key"; KEYD=${KEYF%/*}
CACHE="$XDG_RUNTIME_DIR/salamander/stackshot-pass"; LOG="$SALA_LOG_DIR/salamander-stackshot-key.log"; MARK="$SALA_STATE_DIR/stackshot-key-logged"
KEY="$ROOT/lib/stackshot_key.py"; FORM="$ROOT/lib/stackshot_form.py"; CLIENT="$ROOT/tests/stackshotkey_client.py"; SALA="bash $ROOT/bin/salamander"
export FAKE_OUT="$T/client.records"

# the stub server, and the helper that asks it things
python3 "$ROOT/tests/stackshotkey_stub.py" "$T/port" & STUB_PID=$!
waitfor '[ -s "$T/port" ]' 100 || { bad "the stub server did not start"; echo "stackshotkey: FAIL"; exit 1; }
PORT=$(cat "$T/port"); URL="http://127.0.0.1:$PORT"; export STACKSHOT_URL=$URL
cat > "$T/h.py" <<'PY'
import json, sys, urllib.request
port, verb = sys.argv[1], sys.argv[2]
def get(p): return json.load(urllib.request.urlopen("http://127.0.0.1:%s%s" % (port, p), timeout=10))
if verb == "admin":
    req = urllib.request.Request("http://127.0.0.1:%s/_admin" % port, data=sys.argv[3].encode(), method="POST", headers={"Content-Type": "application/json"})
    urllib.request.urlopen(req, timeout=10).read()
elif verb == "check":      # <python expression over L, the stub's log>: exit 0 when it holds
    L = get("/_admin/log")["log"]
    sys.exit(0 if eval(sys.argv[3]) else 1)
elif verb == "passes":
    print("\n".join(get("/_admin/passes")["passes"]))
elif verb == "records":    # <python expression over R, the fake client's records>
    R = [json.loads(l) for l in open(sys.argv[4]) if l.strip()] if len(sys.argv) > 4 else []
    sys.exit(0 if eval(sys.argv[3]) else 1)
PY
admin() { python3 "$T/h.py" "$PORT" admin "$1"; }
chk() { python3 "$T/h.py" "$PORT" check "$1"; }       # the stub's log, as L
rec() { python3 "$T/h.py" "$PORT" records "$1" "$FAKE_OUT"; }   # the fake client's records, as R
lines() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }
N=0
cap() {  # <cmd…> → runs it with stdin closed, keeps stdout+stderr as out/N, sets OUT and RC
    N=$((N + 1)); OUT=$("$@" 2>&1 </dev/null); RC=$?; printf '%s\n' "$OUT" > "$T/out/$N.txt"
}
reset_fallback() { rm -f "$LOG" "$MARK" "$CACHE" "$CACHE.failed" "$CACHE.lock" "$FAKE_OUT"; }
mode() { stat -c %a "$1" 2>/dev/null; }

echo "== no key yet: the wrapper runs the client plainly, with the machine token, and says why once"
reset_fallback
cap python3 "$KEY" status
[ "$RC" = 0 ] && grep -q '^key: none' <<< "$OUT" && ok "status with no key: 'key: none'" || bad "status with no key: rc=$RC $OUT"
cap python3 "$FORM" run "$CLIENT" post project-agent projects/x some-agent --sender sala-spawn
[ "$RC" = 0 ] && [ "$OUT" = "$(python3 "$CLIENT" post project-agent projects/x some-agent --sender sala-spawn 2>&1 </dev/null)" ] && ok "no key: the client's own output and exit code, byte for byte" || bad "no key: rc=$RC out=$OUT"
rec 'R[0]["credential"] == "machine-token" and R[0]["argv"][:2] == ["post", "project-agent"]' && ok "no key: the client got no pass" || bad "no key: the client was given a pass"
[ "$(lines "$LOG")" = 1 ] && grep -q 'no key yet' "$LOG" && ok "no key: one log line says so" || bad "no key log: $(cat "$LOG" 2>/dev/null)"
[ ! -d "$KEYD" ] && ok "no key: the wrapper made none" || bad "the wrapper made a key"

echo "== init: a private key, once"
cap $SALA stackshot-key init
[ "$RC" = 0 ] && grep -qE '^key: made \([0-9a-f]{16}\)$' <<< "$OUT" && ok "sala stackshot-key init makes the key and prints the short fingerprint only" || bad "init: rc=$RC $OUT"
[ "$(mode "$KEYD")" = 700 ] && [ "$(mode "$KEYF")" = 600 ] && ok "the folder is 0700 and the key file 0600" || bad "modes: $(mode "$KEYD") $(mode "$KEYF")"
SECRET=$(tr -d '\n' < "$KEYF")
[ "${#SECRET}" = 43 ] && [[ $SECRET =~ ^[A-Za-z0-9_-]{43}$ ]] && python3 -c 'import base64,sys; s=sys.argv[1]; assert len(base64.urlsafe_b64decode(s+"="))==32' "$SECRET" && ok "the file holds 32 raw bytes, base64url, 43 characters, no padding" || bad "key shape: ${#SECRET}"
SUM=$(sha256sum < "$KEYF")
cap python3 "$KEY" init
[ "$RC" = 0 ] && grep -qE '^key: already there \(' <<< "$OUT" && [ "$(sha256sum < "$KEYF")" = "$SUM" ] && ok "a second init changes nothing" || bad "second init: $OUT"
rm -f "$T/par."*
pids=(); for i in 1 2 3 4 5 6 7 8; do python3 "$KEY" init > "$T/par.$i" 2>&1 </dev/null & pids+=($!); done; wait "${pids[@]}"
[ "$(sha256sum < "$KEYF")" = "$SUM" ] && [ "$(ls -A "$KEYD" | wc -l | tr -d ' ')" = 1 ] && ok "eight inits at once: the one key as it was, no temporary file left" || bad "parallel init: $(ls -A "$KEYD")"
rm -rf "$T/kd2"; mkdir -p "$T/kd2"; chmod 700 "$T/kd2"; echo junk > "$T/kd2/key"; chmod 600 "$T/kd2/key"
cap env SALA_STACKSHOT_KEY_DIR="$T/kd2" python3 "$KEY" init
[ "$(cat "$T/kd2/key")" = junk ] && ok "an existing key file (even a bad one) is never overwritten" || bad "overwrote a key file"
FP=$(python3 - "$KEYF" <<'PY'
import base64, hashlib, sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization as s
k = Ed25519PrivateKey.from_private_bytes(base64.urlsafe_b64decode(open(sys.argv[1]).read().strip() + "="))
print(hashlib.sha256(k.public_key().public_bytes(s.Encoding.Raw, s.PublicFormat.Raw)).hexdigest())
PY
)
SHORT=${FP:0:16}
cap python3 "$KEY" init
grep -q "$SHORT" <<< "$OUT" && ok "the short fingerprint is the first 16 hex characters of the SHA-256 of the public bytes" || bad "fingerprint: $OUT vs $SHORT"

echo "== status before the server knows the key"
cap python3 "$KEY" status
grep -q '^key: present' <<< "$OUT" && grep -q "^fingerprint: $SHORT\$" <<< "$OUT" && grep -q '^server: unknown' <<< "$OUT" && ok "status: key present, short fingerprint, server unknown (not enrolled)" || bad "status: $OUT"

echo "== enroll"
admin '{"reset_log": true}'
cap $SALA stackshot-key enroll
[ "$RC" = 0 ] && grep -q '^state: pending$' <<< "$OUT" && grep -q "^key: $SHORT\$" <<< "$OUT" && grep -qE '^item: board#[0-9]+$' <<< "$OUT" && grep -q '^next: the owner approves it on that item$' <<< "$OUT" && ok "enroll prints the state, the short fingerprint, the item and what happens next" || bad "enroll: rc=$RC $OUT"
[ "$(wc -l <<< "$OUT")" = 4 ] && ok "and nothing else" || bad "enroll printed more: $OUT"
ITEM=$(sed -n 's/^item: //p' <<< "$OUT")
chk 'len([e for e in L if e["op"]=="enroll"]) == 1 and L[0]["label"]=="sala" and L[0]["sender"]=="sala" and L[0]["public_key_len"]==43 and L[0]["fp"]=="'"$FP"'" and L[0]["status"]==200' && ok "the body: the 43-character public key, label sala, sender sala" || bad "enroll body in the server log"
cap $SALA stackshot-key enroll
[ "$RC" = 0 ] && grep -q '^state: pending$' <<< "$OUT" && grep -q "^item: $ITEM\$" <<< "$OUT" && chk 'len([e for e in L if e["op"]=="enroll" and e["new"]]) == 1' && ok "enroll again: the same state and item, no second key" || bad "repeat enroll: $OUT"

echo "== a key still waiting: pending"
cap python3 "$KEY" status
grep -q '^server: pending$' <<< "$OUT" && ok "status: pending (from a signed claim)" || bad "status pending: $OUT"
reset_fallback
cap python3 "$FORM" run "$CLIENT" post project-agent-retire projects/x agent --sender sala-retire
[ "$RC" = 0 ] && rec 'R[0]["credential"] == "machine-token"' && [ "$(lines "$LOG")" = 1 ] && grep -q 'waiting for the owner' "$LOG" && ok "pending: the machine token, one log line that says it waits for the owner" || bad "pending fallback: $OUT $(cat "$LOG" 2>/dev/null)"

echo "== approved"
admin '{"approve": true}'
cap python3 "$KEY" status
grep -q '^server: approved$' <<< "$OUT" && ok "status: approved when a pass came back" || bad "status approved: $OUT"
cap python3 "$KEY" enroll
[ "$RC" = 0 ] && grep -q '^state: approved$' <<< "$OUT" && grep -q '^item: none' <<< "$OUT" && ok "enroll on an approved key: state approved, no item" || bad "enroll approved: $OUT"

echo "== the claim"
admin '{"reset_log": true}'; rm -f "$CACHE"
cap env STACKSHOT_URL="$URL/" python3 "$KEY" status
chk 'len(L)==1 and L[0]["op"]=="pass" and L[0]["status"]==200 and L[0]["signature_ok"] is True' && ok "a claim signed by the key is traded for a pass (a trailing slash on the address is dropped)" || bad "claim trade"
chk 'L[0]["header_text"]=="{\"alg\":\"EdDSA\"}" and L[0]["payload"]["iss"]=="'"$FP"'" and L[0]["payload"]["aud"]=="'"$URL"'" and set(L[0]["payload"])=={"iss","aud","iat","exp","jti"}' && ok "header {\"alg\":\"EdDSA\"}, iss = the fingerprint, aud = the address without a trailing slash, nothing else in the payload" || bad "claim fields: $(python3 "$T/h.py" "$PORT" check 'print(L[0]) or True')"
chk 'L[0]["payload"]["exp"]-L[0]["payload"]["iat"]==55 and len(L[0]["payload"]["jti"])>=32 and L[0]["claim_len"]<=2048 and abs(L[0]["payload"]["iat"]-__import__("time").time())<30' && ok "life 55 s, jti of 32 or more characters, claim at most 2048 characters, iat now" || bad "claim limits"
rm -f "$CACHE"; cap python3 "$KEY" status
chk 'len({e["payload"]["jti"] for e in L if e["op"]=="pass"})==2' && ok "every claim has a new jti" || bad "jti reused"

echo "== the pass: traded once, reused, in a private cache"
admin '{"reset_log": true}'; reset_fallback
cap python3 "$FORM" run "$CLIENT" post project-agent projects/x one --role r --front --mandate "m" --sender sala-spawn
cap python3 "$FORM" run "$CLIENT" post project-agent-rename projects/x one two --sender sala-rename
cap python3 "$FORM" run "$CLIENT" post project-agent-retire projects/x two --sender sala-retire
chk 'len([e for e in L if e["op"]=="pass"])==1' && ok "three form calls, one trade" || bad "trades: $(python3 "$T/h.py" "$PORT" check 'print(len(L)) or True')"
rec 'len(R)==3 and all(r["credential"]=="pass" for r in R) and len({r["pass_sha12"] for r in R})==1' && ok "the client saw STACKSHOT_CLIENT_PASS on all three, the same pass" || bad "client records: $(cat "$FAKE_OUT")"
SHA=$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline())["pass_sha12"])' "$FAKE_OUT")
chk 'any(e.get("pass_sha12")=="'"$SHA"'" for e in L)' && ok "and it is the pass the server issued" || bad "the pass is not the server's"
[ "$(mode "$XDG_RUNTIME_DIR/salamander")" = 700 ] && [ "$(mode "$CACHE")" = 600 ] && ok "the cache folder is 0700 and its file 0600" || bad "cache modes: $(mode "$XDG_RUNTIME_DIR/salamander") $(mode "$CACHE")"
[ ! -e "$LOG" ] && ok "a pass in use writes no log line" || bad "log written: $(cat "$LOG")"
rm -f "$FAKE_OUT"
cap python3 "$CLIENT" get roles
rec 'R[0]["credential"] == "machine-token"' && ok "a client call that is not the wrapper's (a read) has no pass" || bad "a plain client call got a pass"
[ -z "${STACKSHOT_CLIENT_PASS:-}" ] && ok "the variable is not left in this shell's environment" || bad "STACKSHOT_CLIENT_PASS leaked into the suite's environment"
fp_out=$(python3 "$KEY" form-pass 2>&1 </dev/null); frc=$?     # not kept in out/: it is the pass
[ "$frc" = 0 ] && [[ $fp_out == ssp_* ]] && ok "form-pass (the web app's way) answers the cached pass on a pipe" || bad "form-pass: rc=$frc"
if command -v script >/dev/null 2>&1; then
    tty_out=$(script -qec "python3 $KEY form-pass" /dev/null 2>&1 </dev/null | tr -d '\r')
    grep -q 'ssp_' <<< "$tty_out" && bad "form-pass printed a pass to a terminal" || ok "form-pass never prints a pass on a terminal"
fi
admin '{"reset_log": true}'
python3 - "$CACHE" <<'PY'
import json, sys, time
d = json.load(open(sys.argv[1])); d["exp"] = time.time() + 30; json.dump(d, open(sys.argv[1], "w"))
PY
cap python3 "$FORM" run "$CLIENT" post project-agent projects/x one --sender sala-spawn
chk 'len([e for e in L if e["op"]=="pass"])==1' && ok "a cached pass with under 60 s left is not reused: a new trade" || bad "a nearly expired pass was reused"
python3 - "$CACHE" <<'PY'
import json, sys, time
d = json.load(open(sys.argv[1])); d["exp"] = time.time() + 120; json.dump(d, open(sys.argv[1], "w"))
PY
admin '{"reset_log": true}'
cap python3 "$FORM" run "$CLIENT" post project-agent projects/x one --sender sala-spawn
chk 'len([e for e in L if e["op"]=="pass"])==0' && ok "one with 120 s left is reused: no trade" || bad "a good pass was traded again"
cap env STACKSHOT_URL="http://127.0.0.1:$PORT/" python3 "$FORM" run "$CLIENT" post project-agent projects/x one --sender sala-spawn
chk 'len([e for e in L if e["op"]=="pass"])==0' && ok "the address with a trailing slash is the same address (no trade)" || bad "trailing slash traded again"

echo "== the wrapper keeps the client's own behavior"
rm -f "$FAKE_OUT"
printf 'a\nb\nc\n' | python3 "$FORM" run "$CLIENT" post project-agent x y > "$T/w.out" 2> "$T/w.err"; wrc=$?
printf 'a\nb\nc\n' | env -u STACKSHOT_CLIENT_PASS python3 "$CLIENT" post project-agent x y > "$T/d.out" 2> "$T/d.err"; drc=$?
[ "$wrc" = "$drc" ] && cmp -s "$T/w.out" "$T/d.out" && cmp -s "$T/w.err" "$T/d.err" && grep -q 'stdin lines: 3' "$T/w.out" && ok "standard input is forwarded; stdout, stderr and exit code equal the client's own" || bad "wrapper vs direct: $wrc/$drc"
FAKE_RC=7 python3 "$FORM" run "$CLIENT" post project-agent x y >/dev/null 2>&1 </dev/null; [ "$?" = 7 ] && ok "the client's exit code (7) is the wrapper's" || bad "exit code lost"
python3 "$FORM" run "$T/no-such-client.py" post x >/dev/null 2>&1 </dev/null; [ "$?" = 2 ] && ok "a client path that does not exist: python's own exit 2, as without the wrapper" || bad "missing client: rc=$?"
python3 "$FORM" nonsense >/dev/null 2>&1; [ "$?" = 2 ] && ok "a wrong call to the wrapper is a usage error (2)" || bad "wrapper usage"
rec 'R[0]["credential"]=="pass" and R[0]["stdin_lines"]==3' && ok "the pass was in the client's environment for the call" || bad "client record: $(head -c 300 "$FAKE_OUT")"
cap env STACKSHOT_CLIENT_PASS=ssp_from_outside python3 "$FORM" run "$CLIENT" post project-agent x y
rec 'R[-1]["pass_sha12"] != __import__("hashlib").sha256(b"ssp_from_outside").hexdigest()[:12]' && ok "a pass value set outside is replaced by sala's own, never forwarded" || bad "an outside value was forwarded"

echo "== fallbacks: the client runs with the machine token, exits as it alone does, one log line per five minutes"
fb() {  # <name> <log keyword|-> <env assignments…> → the wrapper twice under that condition
    local name=$1 kw=$2; shift 2
    reset_fallback
    printf 'x\n' | env "$@" python3 "$FORM" run "$CLIENT" post project-agent projects/x a --sender sala-spawn > "$T/f.out" 2> "$T/f.err"; local rc=$?
    printf 'x\n' | env -u STACKSHOT_CLIENT_PASS python3 "$CLIENT" post project-agent projects/x a --sender sala-spawn > "$T/g.out" 2> "$T/g.err"; local drc=$?
    cat "$T/f.out" "$T/f.err" >> "$T/out/fb-$name.txt"
    [ "$rc" = "$drc" ] && cmp -s "$T/f.out" "$T/g.out" && cmp -s "$T/f.err" "$T/g.err" && ok "$name: exit code and output are the client's own" || bad "$name: rc $rc vs $drc"
    rec 'R[0]["credential"]=="machine-token"' && ok "$name: the machine token (no pass in the client's environment)" || bad "$name: the client got a pass"
    if [ "$kw" = - ]; then
        [ ! -e "$LOG" ] && ok "$name: silent, as asked" || bad "$name: wrote a log line: $(cat "$LOG")"
    else
        [ "$(lines "$LOG")" = 1 ] && grep -q "$kw" "$LOG" && ok "$name: one log line, naming '$kw'" || bad "$name: log: $(cat "$LOG" 2>/dev/null)"
        env "$@" python3 "$FORM" run "$CLIENT" post project-agent projects/x a --sender sala-spawn >/dev/null 2>&1 </dev/null
        [ "$(lines "$LOG")" = 1 ] && ok "$name: a second call within five minutes adds no line" || bad "$name: log grew: $(cat "$LOG")"
        touch -d '10 minutes ago' "$MARK"
        env "$@" python3 "$FORM" run "$CLIENT" post project-agent projects/x a --sender sala-spawn >/dev/null 2>&1 </dev/null
        [ "$(lines "$LOG")" = 2 ] && ok "$name: after five minutes the next call logs again" || bad "$name: log after ageing: $(cat "$LOG")"
    fi
}
fb unreachable 'not reached' STACKSHOT_URL=http://127.0.0.1:1
admin '{"fail": 500}'; fb server-500 'HTTP 500' X=1; admin '{"fail": 429}'; fb server-429 'HTTP 429' X=1; admin '{"fail": 401}'; fb server-401 'HTTP 401' X=1; admin '{"fail": 0}'
mkdir -p "$T/nocrypto/cryptography"; echo 'raise ImportError("simulated: no cryptography")' > "$T/nocrypto/cryptography/__init__.py"
fb library-missing 'cryptography is missing' PYTHONPATH="$T/nocrypto"
chmod 644 "$KEYF"; fb key-open-to-others 'readable by others' X=1; chmod 600 "$KEYF"
fb switched-off - SALA_STACKSHOT_PASS=off
fb no-server-address 'no stackshot server address' STACKSHOT_URL= HOME="$T/home"
mv "$KEYF" "$T/key.moved"; fb no-key 'no key yet' X=1; mv "$T/key.moved" "$KEYF"
cp "$KEYF" "$T/key.keep"; printf 'garbage\n' > "$KEYF"; fb bad-key-file 'not a key sala made' X=1; cp "$T/key.keep" "$KEYF"; chmod 600 "$KEYF"
[ "$(sha256sum < "$KEYF")" = "$SUM" ] && ok "no fallback touched the key file" || bad "the key file changed"
reset_fallback; admin '{"fail": 500}'
python3 "$FORM" run "$CLIENT" post project-agent x y >/dev/null 2>&1 </dev/null
admin '{"fail": 0, "reset_log": true}'
SALA_STACKSHOT_PASS_BACKOFF=30 python3 "$FORM" run "$CLIENT" post project-agent x y >/dev/null 2>&1 </dev/null
chk 'len([e for e in L if e["op"]=="pass"])==0' && ok "a trade that just failed is not asked again within the backoff (30 s here)" || bad "no backoff"
SALA_STACKSHOT_PASS_BACKOFF=0 python3 "$FORM" run "$CLIENT" post project-agent x y >/dev/null 2>&1 </dev/null
chk 'len([e for e in L if e["op"]=="pass"])==1' && ok "with the backoff over, the next call trades and gets its pass" || bad "no trade after the backoff"

echo "== the key's verb"
cap $SALA stackshot-key
[ "$RC" = 2 ] && grep -q 'usage: sala stackshot-key init' <<< "$OUT" && ok "no argument: the usage, exit 2" || bad "no argument: rc=$RC"
cap $SALA stackshot-key --help
[ "$RC" = 0 ] && grep -q 'enroll' <<< "$OUT" && ok "--help: the usage, exit 0" || bad "--help: rc=$RC"
cap $SALA stackshot-key bogus
[ "$RC" = 2 ] && ok "an unknown argument: exit 2" || bad "bogus: rc=$RC"
cap $SALA stackshot-key status
[ "$RC" = 0 ] && grep -q '^server: approved$' <<< "$OUT" && ok "sala stackshot-key status through the verb" || bad "verb status: $OUT"
cap env STACKSHOT_URL=http://127.0.0.1:1 python3 "$KEY" enroll
[ "$RC" = 1 ] && grep -q 'was not reached' <<< "$OUT" && ok "enroll with the server down: an error line, exit 1, the key kept" || bad "enroll down: rc=$RC $OUT"
cap env STACKSHOT_URL=http://127.0.0.1:1 python3 "$KEY" status
[ "$RC" = 0 ] && grep -q '^server: unknown (the server was not reached' <<< "$OUT" && ok "status with the server down: unknown, with the reason" || bad "status down: $OUT"

echo "== the call sites go through the wrapper"
rm -f "$FAKE_OUT"; rm -f "$CACHE"; admin '{"reset_log": true}'
sx() { SALA_CONFIG=/dev/null SALA_ROOT="$ROOT" SALA_STACKSHOT_CLIENT="$CLIENT" bash -c '. "$SALA_ROOT/lib/common.sh"; '"$1" 2>&1; }
sx 'agent_register projects/x some-agent r front "a mandate"; echo "rc=$?"' > "$T/out/site1.txt"
sx 'RL_HUB=projects/x; rename_list_run old-agent new-agent; echo "rc=$?"' > "$T/out/site2.txt"
sx 'RL_HUB=projects/x RL_ROLE=r RL_LINE="a line"; rename_side_run new-agent; echo "rc=$?"' > "$T/out/site3.txt"
sx '_retire_call some-agent projects/x; echo "rc=$?"' > "$T/out/site4.txt"
rec 'len(R)==4 and all(r["credential"]=="pass" for r in R)' && ok "agent_register, rename_list_run, rename_side_run and _retire_call all ran the client with the pass" || bad "call sites: $(cut -c1-200 "$FAKE_OUT")"
rec '[r["argv"][:2] for r in R]==[["post","project-agent"],["post","project-agent-rename"],["post","project-agent"],["post","project-agent-retire"]]' && ok "and with the arguments they always had (post project-agent, -rename, project-agent, -retire)" || bad "call site arguments: $(cut -c1-300 "$FAKE_OUT")"
rec 'all(r["argv"][r["argv"].index("--sender")+1].startswith("sala-") for r in R)' && ok "every sender label of those calls starts with sala-" || bad "a sender label does not start with sala-"
chk 'len([e for e in L if e["op"]=="pass"])==1' && ok "four calls of one command line family: one trade" || bad "call sites traded more than once"
# the labels sala sends, as the defaults say (read from the code, not a copy of them)
labels=$(sx 'printf "%s\n" "$SALA_SPAWN_SENDER" "$SALA_RENAME_SENDER" "$SALA_RENAME_LIST_SENDER" "$SALA_RETIRE_SENDER"')
badlabel=""; while IFS= read -r l; do case "$l" in sala-?*) ;; *) badlabel="$badlabel [$l]" ;; esac; done <<< "$labels"
[ -z "$badlabel" ] && [ "$(grep -c . <<< "$labels")" = 4 ] && ok "the default labels of spawn, rename, rename-list and retire start with sala-: $(tr '\n' ' ' <<< "$labels")" || bad "labels: $labels $badlabel"
grep -q '"SALA_BGAGENTS_SENDER") or "sala-web"' "$ROOT/lib/bgagents.py" && ok "bg-agents' default label is sala-web" || bad "bg-agents' default label changed"
grep -hn '^SENDER = ' "$ROOT"/web/src/sala_web/*.py | grep -q 'SENDER = "sala-web"' && ok "the web app's one label is sala-web" || bad "the web app's label is not sala-web"
grep -q 'python3 \$SALA_FORM_PY run \$_bg_client post project-agent' "$ROOT/lib/bgagents.sh" && ok "bg-agents' default post command is the wrapper around the client" || bad "bgagents.sh's default post command is not the wrapper"
bad_sites=$(grep -n 'python3 "\$[A-Za-z_]*" post project-agent' "$ROOT"/lib/*.sh | grep -v '^.*:[0-9]*:[[:space:]]*#' || true)
[ -z "$bad_sites" ] && ok "no form call in lib/ still runs the client directly" || bad "a form call bypasses the wrapper: $bad_sites"
grep -q 'post terminal-prompt' "$ROOT/lib/stuck.sh" && ! grep -q 'stackshot_form' "$ROOT/lib/stuck.sh" && ok "a call that is not the form's (stuck's terminal-prompt row) keeps the machine token: not wrapped" || bad "stuck.sh changed"
grep -q 'SALA_BGAGENTS_POST_CMD+x' "$ROOT/lib/bgagents.sh" && ok "an explicit SALA_BGAGENTS_POST_CMD still wins (used as written, not wrapped)" || bad "the override is gone"

echo "== no secret anywhere"
for i in $(python3 "$T/h.py" "$PORT" passes); do PASSES="${PASSES:-}$i"$'\n'; done
[ -n "${PASSES:-}" ] && ok "the server issued $(grep -c . <<< "$PASSES") passes in this run" || bad "no pass was ever issued: the checks below prove nothing"
leak=0
while IFS= read -r p; do
    [ -n "$p" ] || continue
    if grep -rqF -- "$p" "$T/out" "$LOG" "$SALA_LOG_DIR" "$T/w.out" "$T/w.err" "$T/f.out" "$T/f.err" "$FAKE_OUT" 2>/dev/null; then leak=1; echo "  a pass is in a kept output"; fi
done <<< "$PASSES"
[ "$leak" = 0 ] && ok "no pass the server issued is in any output, log or client record the suite kept" || bad "a pass leaked"
if grep -rqF -- "$SECRET" "$T/out" "$SALA_LOG_DIR" "$FAKE_OUT" "$T/w.out" "$T/w.err" "$T/f.out" "$T/f.err" "$T/h.py" 2>/dev/null; then bad "the private key is in a kept output"; else ok "the private key is in no output, log or client record"; fi
others=$(grep -rlF --exclude=key -- "$SECRET" "$HOME" "$XDG_STATE_HOME/salamander" 2>/dev/null | sed "s|^$T/||")
[ -n "$others" ] && bad "the private key is in a file other than its own: $others" || ok "the private key is in no file but its own"
if grep -rqF -- "$SECRET" "$XDG_RUNTIME_DIR" 2>/dev/null; then bad "the private key is in the pass cache"; else ok "the private key is not in the pass cache"; fi
python3 - "$ROOT" <<'PY' && ok "the sources never put a key or a pass in an argv, an environment variable of its own, or a print (read as text)" || bad "a source prints or passes a secret"
import re, sys
src = open(sys.argv[1] + "/lib/stackshot_key.py").read()
form = open(sys.argv[1] + "/lib/stackshot_form.py").read()
bad = []
# the only print of a pass is form-pass's write to stdout; the private key's text is never formatted into a message
if len(re.findall(r"sys\.stdout\.write\(pw", src)) != 1: bad.append("pass write")
if re.search(r"(print|_fail|note)\([^)]*(SECRET|raw|b64u\(raw)", src): bad.append("key in a message")
if re.search(r"subprocess|os\.system", src + form): bad.append("a subprocess")
if "STACKSHOT_CLIENT_PASS" in src: bad.append("the variable in the key module")
sys.exit(1 if bad else 0)
PY
[ "$(stat -c %a "$CACHE")" = 600 ] && ok "the cache file stays 0600 to the end" || bad "cache mode at the end: $(mode "$CACHE")"

[ "$fail" = 0 ] && echo "stackshotkey: pass" || echo "stackshotkey: FAIL"
exit "$fail"
