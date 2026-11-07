#!/usr/bin/env bash
# the lean morning summary. gmail_fetch.py reads and trims the unread mail in CODE (the portal's Gmail reads over
# MCP HTTP with Claude Code's stored portal login), summary-lean.sh makes ONE model call with no tools from it and, by
# default, posts nothing (it writes lean/YYYYMMDD.txt in its log directory), --post delivers like summary.sh.
# Part 1, gmail_fetch.py against tests/briefing/lean_fake_portal.py (a listener on 127.0.0.1, made-up mail in the shapes
# the real server's shapes): the right requests (bearer token, own user agent, a session, only the five Gmail reads, each passing guard.py);
# trimming (quoted reply, signature, footer, HTML, links, Google Alerts with real titles and URLs, the cap); the thread id
# on every item; the data block cannot be closed by a mail; the token printed nowhere; an expired token, a refused login,
# an OAuth answer, a garbage answer, an unreachable portal and a JSON-RPC error each end as a distinct non-zero exit.
# Part 2, summary-lean.sh with a stubbed fetch and a fake `claude`: the model call's exact flags, the system prompt, the
# mail on stdin, the model from lib.sh, the environment untouched (an AWS lane's variables pass); the count line is code's;
# the default run posts nothing and --post / BRIEFING_LEAN_POST=1 posts once; a fetch error, an auth error and a run without
# a Gmail read each end as a loud notice and never as a digest, the model never called; lean-compare.sh; the units.
# Nothing reaches Gmail, Slack, the real portal or the real credentials.
set -u
export BRIEFING_GMAIL_CONNECTOR=demo   # a made-up connector word (config.example): the tools are mcp__claude_ai_Google_Workspace_demo__* and the portal's gdemo_*
ROOT=$(cd "$(dirname "$0")/../.." && pwd); D=$ROOT/contrib/briefing; TD=$ROOT/tests/briefing
fail=0; ok() { echo "  ok   $*"; }; bad() { echo "  FAIL $*"; fail=1; }
T=$(mktemp -d); trap 'kill ${SRV:-} ${HOOK:-} 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/logs" "$T/bin" "$T/home"
TOKEN=lean-SECRET-token-5e1d9c
PIDS=

# ---------------------------------------------------------------------------------------------------- part 1
echo ok > "$T/mode"
python3 "$TD/lean_fake_portal.py" "$T/port" "$T/calls" "$TOKEN" "$T/mode" &
SRV=$!
for _ in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
[ -s "$T/port" ] || { bad "the fake portal did not start"; exit 1; }
PORT=$(cat "$T/port")
mkcred() { # mkcred <file> <seconds until the token expires> [token] [port]
    python3 -I - "$1" "$2" "${3:-$TOKEN}" "${4:-$PORT}" <<'PY'
import json, sys, time
f, left, tok, port = sys.argv[1:5]
json.dump({"mcpOAuth": {"other|1": {"serverName": "Slack", "serverUrl": "https://example.invalid/mcp", "accessToken": "not-the-portal"},
    "mcp-portal|abc": {"serverName": "mcp-portal", "serverUrl": f"http://127.0.0.1:{port}/mcp", "accessToken": tok,
                       "refreshToken": "refresh-must-never-be-used", "expiresAt": int((time.time() + float(left)) * 1000)}}}, open(f, "w"))
PY
}
mkcred "$T/cred.json" 3600
fetch() { # fetch [env…] -- runs gmail_fetch.py against the fake; stdout in $T/out, stderr in $T/err, meta in $T/meta
    rm -f "$T/meta"
    env TZ=Etc/GMT-4 BRIEFING_LEAN_CREDENTIALS="$T/cred.json" "$@" python3 -I "$D/gmail_fetch.py" --meta-file "$T/meta" > "$T/out" 2> "$T/err"
}
: > "$T/calls"; fetch; rc=$?
[ $rc = 0 ] && grep -q '^<unread-mail-data unread="7" threads="6" shown="6" omitted="0">$' "$T/out" && tail -1 "$T/out" | grep -qx '</unread-mail-data>' \
    && ok "fetch: exit 0, the framed block with the unread count (7 messages in 6 threads)" || bad "fetch rc=$rc: $(head -3 "$T/out") err=$(cat "$T/err")"
grep -q '"reads": 2' "$T/meta" && grep -q '"unread": 7' "$T/meta" && grep -q '"more": false' "$T/meta" && ok "fetch: the meta file counts the unread mail and the reads (the delivery guard's evidence)" || bad "meta: $(cat "$T/meta")"

# the requests: only the five Gmail reads, one tool, the token as a bearer header, own user agent, a session
cut -f1,2 "$T/calls" | sort -u > "$T/tools"
[ "$(cut -f1 "$T/tools" | sort -u)" = portal_codemode_execute ] && ! grep -v -E 'gdemo_(search_gmail_messages|get_gmail_message_content|get_gmail_messages_content_batch|get_gmail_thread_content|get_gmail_threads_content_batch)$' <(cut -f2 "$T/tools") | grep -q . \
    && [ "$(grep -c . "$T/calls")" = 2 ] && ! grep -v auth_ok "$T/calls" | grep -q . \
    && ok "fetch: two calls, portal_codemode_execute with gdemo_search_gmail_messages and ..._get_gmail_messages_content_batch, bearer token accepted" || bad "calls: $(cat "$T/calls" | cut -c1-120)"
python3 -I - "$D" <<'PY' && ok "read_code: a send, a draft, a label change or a Drive tool is refused before anything is sent; the five reads pass guard.py" || bad "read_code did not enforce the five reads"
import importlib.util, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("gf", sys.argv[1] + "/gmail_fetch.py"); gf = importlib.util.module_from_spec(spec); spec.loader.exec_module(gf)
for t in gf.READS:
    gf.read_code(t, {"query": "is:unread", "page_size": 3, "message_ids": ["abc"], "thread_ids": ["abc"], "message_id": "a", "thread_id": "a"})
for t in ("gdemo_send_gmail_message", "gdemo_draft_gmail_message", "gdemo_modify_gmail_message_labels", "gdemo_search_drive_files", "gdemo_manage_gmail_filter", "x"):
    try: gf.read_code(t, {}); sys.exit(1)
    except gf.FetchError: pass
PY

# trimming
mail=$(cat "$T/out")
printf '%s\n' "$mail" | grep -q QUOTEDLINE && bad "a quoted reply got through" || ok "trim: the quoted reply (On … wrote: and > lines) is cut"
printf '%s\n' "$mail" | grep -q 'SIGNATURELINE' && bad "a signature got through" || ok "trim: a signature after '-- ' is cut"
printf '%s\n' "$mail" | grep -q 'FOOTERTAIL' && bad "a newsletter footer got through" || ok "trim: a newsletter's text after 'unsubscribe' is cut"
printf '%s\n' "$mail" | grep -q 'docs.example.com' && bad "a link in a human mail was kept" || { printf '%s\n' "$mail" | grep -q '\[link\]' && ok "trim: links in ordinary mail become [link]"; }
printf '%s\n' "$mail" | grep -q '<html>\|<div>\|<style>\|color:red' && bad "HTML got through" || { printf '%s\n' "$mail" | grep -qF 'Body: Your invoice INV-77 failed ⏎ Please update your card.' && ok "trim: an HTML-only mail becomes text (tags and style gone)"; }
nl=$(printf '%s\n' "$mail" | grep -A1 '^Subject: Weekly digest' | tail -1 | wc -m)
[ "$nl" -le 420 ] && ok "trim: a long newsletter is cut to a few hundred characters ($nl)" || bad "newsletter body $nl characters"
printf '%s\n' "$mail" | grep -qF 'Date: Wed Oct 21st 05:15' && printf '%s\n' "$mail" | grep -qF 'Date: Wed Oct 21st 08:00' \
    && ok "trim: dates are in the TZ zone, in the owner's form (here UTC+4: 01:15 UTC Oct 21st = Wed Oct 21st 05:15, 24-hour)" || bad "dates: $(printf '%s\n' "$mail" | grep '^Date:')"
# the date formatter itself: the owner's form `Mon Oct 26th 09:03`, in the TZ zone (fixed UTC+4 here), weekday and ordinal suffix from tables
out=$(TZ=Etc/GMT-4 python3 -I - "$D/gmail_fetch.py" <<'PY' 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("gmail_fetch", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
bad = []
def chk(got, want):
    if got != want: bad.append(f"{got!r} != {want!r}")
for n, want in [(1, "1st"), (2, "2nd"), (3, "3rd"), (4, "4th"), (10, "10th"), (11, "11th"), (12, "12th"), (13, "13th"), (14, "14th"),
                (20, "20th"), (21, "21st"), (22, "22nd"), (23, "23rd"), (24, "24th"), (30, "30th"), (31, "31st")]:
    chk(m.ordinal(n), want)
# 05:03 UTC Mon Oct 26th 2026 = 09:03 at UTC+4 the same day
chk(m.local_time("Mon, 26 Oct 2026 05:03:00 +0000")[1], "Mon Oct 26th 09:03")
chk(m.local_time("Mon, 26 Oct 2026 09:03:00 +0400")[1], "Mon Oct 26th 09:03")
chk(m.local_time("Mon, 26 Oct 2026 14:03:00 -0700")[1], "Tue Oct 27th 01:03")      # another zone: converted to the local one, the day moves
chk(m.local_time("Sun, 25 Oct 2026 20:30:00 +0000")[1], "Mon Oct 26th 00:30")      # past midnight local: next day, 24-hour 00:30
chk(m.local_time("Sun, 01 Nov 2026 08:00:00 +0000")[1], "Sun Nov 1st 12:00")
chk(m.local_time("Sat, 12 Dec 2026 03:00:00 +0000")[1], "Sat Dec 12th 07:00")      # 12th, not 12nd
chk(m.local_time("Thu, 31 Dec 2026 19:59:00 +0000")[1], "Thu Dec 31st 23:59")
chk(m.local_time("Thu, 31 Dec 2026 20:00:00 +0000")[1], "Fri Jan 1st 00:00")       # year rollover
chk(m.local_time("not a date")[1], "unknown date")
chk(m.local_time("")[1], "unknown date")
import datetime
chk(m.fmt_local(datetime.datetime(2026, 10, 26, 5, 3, tzinfo=datetime.timezone.utc)), "Mon Oct 26th 09:03")
print("\n".join(bad) if bad else "ALL GOOD")
PY
)
[ "$out" = "ALL GOOD" ] && ok "date formatter: ordinals (1st 2nd 3rd 4th 11th 12th 13th 21st 22nd 23rd 31st), weekday, zone conversion across midnight and year end, a bad date" || bad "date formatter: $out"
printf '%s\n' "$mail" | grep -q '^\[3\] thread=18c0b00000000001 kind=human unread_in_thread=2$' \
    && printf '%s\n' "$mail" | grep -qF 'Can you review the contract draft by Friday?' && printf '%s\n' "$mail" | grep -qF 'Also, the deadline moved to Thursday.' \
    && ok "thread: two unread messages of one thread are one item (unread_in_thread=2) carrying both messages' new text" || bad "thread item: $(printf '%s\n' "$mail" | sed -n '/^\[3\]/,/^$/p')"
n=$(printf '%s\n' "$mail" | grep -c '^\[[0-9]*\] thread=[0-9a-f]\{16\} kind=')
[ "$n" = 6 ] && ok "every item carries its Gmail thread id (the [gmail:THREAD_ID] marker rule)" || bad "thread ids: $n of 6"
printf '%s\n' "$mail" | grep -qF -- '- Acme Labs raises $30M for drip irrigation data sharing | ... Acme Labs announced a new round to scale water-saving irrigation across regional farms. | https://news.example.com/acme-raises' \
    && ok "alerts: the wrapped article title is joined, the snippet kept, the destination URL taken out of the google.com/url redirect" || bad "alert item: $(printf '%s\n' "$mail" | sed -n '/^\[6\]/,$p')"
printf '%s\n' "$mail" | grep -qF 'https://blog.example.org/foo-v2?id=5' && ! printf '%s\n' "$mail" | grep -q 'google.com/url\|FOOTERALERT\|alerts/remove' \
    && ok "alerts: an escaped URL is decoded, the redirect and the alert footer are gone" || bad "alert url/footer: $(printf '%s\n' "$mail" | grep -c 'google.com')"
[ "$(printf '%s\n' "$mail" | grep -c 'foo-v2')" = 1 ] && ok "alerts: the same article in two alert mails is passed once" || bad "repeat article: $(printf '%s\n' "$mail" | grep -c foo-v2)"
[ "$(printf '%s\n' "$mail" | grep -c '</unread-mail-data>')" = 1 ] && [ "$(printf '%s\n' "$mail" | grep -c '<unread-mail-data')" = 1 ] \
    && ok "a hostile mail (a closing tag in its subject and body) cannot close or reopen the data block" || bad "frame: $(printf '%s\n' "$mail" | grep -c 'unread-mail-data')"
[ "$(printf '%s\n' "$mail" | grep '^\[' | sed 's/^\[[0-9]*\] thread=[0-9a-f]* kind=\([a-z]*\).*/\1/' | tr '\n' ' ')" = 'human human human automated alert alert ' ] \
    && ok "order: human mail first (newest first), then automated, then alerts" || bad "order: $(printf '%s\n' "$mail" | grep '^\[' | cut -c1-60)"
grep -qF "$TOKEN" "$T/out" "$T/err" "$T/meta" && bad "the token reached the output" || ok "the token is in no output (stdout, stderr, meta)"
if grep -q 'refresh-must-never-be-used' "$T/out" "$T/err" "$T/calls" "$T/meta" || grep -qi 'refresh' "$T/calls"; then bad "the refresh token reached an output or a request"; else ok "the refresh token is never used: it is in no request, output or call log, and no refresh call was made"; fi

# the cap and the rest of a big mailbox
echo many > "$T/mode"; : > "$T/calls"
fetch BRIEFING_LEAN_MAX_CHARS=6000; rc=$?
sz=$(wc -c < "$T/out"); oms=$(sed -n 's/.*omitted="\([0-9]*\)".*/\1/p' "$T/out" | head -1)
[ $rc = 0 ] && [ "$sz" -le 6600 ] && [ "${oms:-0}" -gt 0 ] && grep -q 'unread="67"' "$T/out" && grep -q '"unread": 67' "$T/meta" \
    && ok "cap: 67 unread messages and a 6000-character cap give a block of $sz bytes with $oms threads counted as omitted; the unread count stays 67" || bad "cap: rc=$rc size=$sz omitted=$oms $(head -1 "$T/out")"
[ "$(grep -c 'getmessages\|get_gmail_messages_content_batch' "$T/calls")" = 9 ] && ok "a big mailbox: message contents are read 8 at a time, trimmed in the portal (9 batches for 67)" || bad "batches: $(grep -c batch "$T/calls")"
grep -q 'kind=human' "$T/out" && ! grep -q 'kind=alert' "$T/out" && ok "cap: what is dropped is the lowest priority (alerts before human mail)" || bad "cap order"

echo empty > "$T/mode"
fetch; rc=$?
[ $rc = 0 ] && grep -q 'unread="0"' "$T/out" && grep -q '(no unread mail)' "$T/out" && grep -q '"reads": 1' "$T/meta" \
    && ok "an empty mailbox: exit 0, a block that says so, one read counted (the digest still goes out)" || bad "empty: rc=$rc $(cat "$T/out") $(cat "$T/meta" 2>/dev/null)"
echo paged > "$T/mode"
fetch; grep -q 'unread="7+"' "$T/out" && grep -q '"more": true' "$T/meta" && ok "a next page the portal masks: the unread count is '7+', never a silent 7" || bad "paged: $(head -1 "$T/out")"

# the portal's size limit: Code Mode cuts an answer at 24000 characters. An early run asked for 25 full messages per read,
# every answer came back cut and unparseable, and the threads reached the model with nothing in them.
one_err_empty() { [ "$(wc -l < "$T/err")" = 1 ] && [ ! -s "$T/out" ] && [ ! -e "$T/meta" ]; }
echo bigbodies > "$T/mode"; : > "$T/calls"
fetch BRIEFING_LEAN_MAX_CHARS=100000; rc=$?
nb=$(grep -c 'get_gmail_messages_content_batch' "$T/calls")
[ $rc = 0 ] && grep -q '"unread": 67' "$T/meta" && grep -q '"empty": 0' "$T/meta" && [ "$(grep -c '^Subject: Question number' "$T/out")" -ge 60 ] && [ "$nb" -gt 9 ] && [ ! -s "$T/err" ] \
    && ok "size limit: 67 mails of 9000 characters (8 trimmed to 3000 each are still over 24000): the cut batches are split in halves ($nb batch reads) and every thread keeps its subject, sender and date" || bad "bigbodies: rc=$rc batches=$nb $(cat "$T/meta" 2>/dev/null) err=$(cat "$T/err")"
grep -q 'Big body of mail' "$T/out" && ! grep -q 'TRUNCATED' "$T/out" && ok "size limit: the portal's cut notice never reaches the block" || bad "bigbodies body/notice"
python3 -I - "$D" <<'PY' && ok "decode_cut: a result string cut mid-way (even inside an escape) is read up to the cut; text that is not a cut answer is left alone" || bad "decode_cut"
import importlib.util, json, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("gf", sys.argv[1] + "/gmail_fetch.py"); gf = importlib.util.module_from_spec(spec); spec.loader.exec_module(gf)
full = json.dumps({"result": "Retrieved 2 messages:\n\nMessage ID: aaa\nSubject: Hi \"there\"\nFrom: A <a@example.com>\n\n--- BODY ---\nline\nmore"}, indent=2)
tail = "\n\n--- TRUNCATED ---\nResponse was ~16,705 tokens. Use more specific code to filter results."
for cut in (len(full) - 9, full.index('\\"there') + 1, full.index("\\n") + 1):   # mid-string, inside an escape, right after a backslash
    got = gf.decode_cut(full[:cut] + tail)
    assert got is not None and got.startswith("Retrieved 2 messages:"), (cut, got)
assert "Subject: Hi" in gf.decode_cut(full[:len(full) - 9] + tail)
assert gf.decode_cut(full) is None and gf.decode_cut("<html>maintenance</html>") is None and gf.decode_cut('{"result": "x"') is None
PY
for mode in stripped emptyfirst emptyshare; do
    echo $mode > "$T/mode"; fetch; rc=$?
    [ $rc = 4 ] && one_err_empty && grep -q 'Gmail came back with empty threads' "$T/err" \
        && ok "empty threads ($mode): exit 4, 'Gmail came back with empty threads', no block, no meta, so no digest" || bad "$mode: rc=$rc err=$(cat "$T/err") out=$(head -c 100 "$T/out")"
done
echo emptylate > "$T/mode"; fetch; rc=$?
[ $rc = 0 ] && grep -q '"empty": 1' "$T/meta" && grep -q '"unread": 67' "$T/meta" && ok "one empty thread among 67, not among the first five: the run goes on and the meta counts it" || bad "emptylate: rc=$rc $(cat "$T/meta" 2>/dev/null) $(cat "$T/err")"
echo ok > "$T/mode"

# failures: each a distinct exit, one stderr line, no block, no meta, no token
one_err() { [ "$(wc -l < "$T/err")" = 1 ] && [ ! -s "$T/out" ] && [ ! -e "$T/meta" ] && ! grep -qF "$TOKEN" "$T/err"; }
echo 401 > "$T/mode"; fetch; rc=$?
[ $rc = 3 ] && one_err && grep -q 'HTTP 401' "$T/err" && ok "a refused login (HTTP 401): exit 3, one line, nothing on stdout" || bad "401: rc=$rc $(cat "$T/err")"
echo oauth > "$T/mode"; fetch; rc=$?
[ $rc = 3 ] && one_err && ok "Gmail answering 'needs re-authorization': exit 3" || bad "oauth: rc=$rc $(cat "$T/err")"
echo garbage > "$T/mode"; fetch; rc=$?
[ $rc = 4 ] && one_err && ok "an answer that is neither results nor 'none': exit 4 (never read as an empty mailbox)" || bad "garbage: rc=$rc $(cat "$T/err")"
echo rpcerror > "$T/mode"; fetch; rc=$?
[ $rc = 4 ] && one_err && ok "a JSON-RPC error from the portal: exit 4" || bad "rpcerror: rc=$rc $(cat "$T/err")"
echo ok > "$T/mode"
mkcred "$T/cred-bad.json" 3600 "$TOKEN-wrong"; fetch BRIEFING_LEAN_CREDENTIALS="$T/cred-bad.json"; rc=$?
[ $rc = 3 ] && one_err && ! grep -qF "$TOKEN-wrong" "$T/err" && ok "a token the portal does not know: exit 3, and even the wrong token is not echoed" || bad "wrong token: rc=$rc $(cat "$T/err")"
fetch BRIEFING_LEAN_CREDENTIALS="$T/none.json"; rc=$?
[ $rc = 3 ] && one_err && ok "no login file: exit 3" || bad "no creds: rc=$rc $(cat "$T/err")"
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); [v.pop("serverUrl", None) for v in d["mcpOAuth"].values()]; json.dump(d, open(sys.argv[2], "w"))' "$T/cred.json" "$T/cred-nourl.json"
: > "$T/calls"; fetch BRIEFING_LEAN_PORTAL_URL= BRIEFING_LEAN_CREDENTIALS="$T/cred-nourl.json"; rc=$?
[ $rc = 4 ] && one_err && grep -q 'BRIEFING_LEAN_PORTAL_URL' "$T/err" && [ ! -s "$T/calls" ] && ok "no portal address (no serverUrl, no BRIEFING_LEAN_PORTAL_URL): exit 4 naming the setting, nothing sent" || bad "no url: rc=$rc $(cat "$T/err")"
fetch BRIEFING_LEAN_PORTAL_URL="http://127.0.0.1:$PORT/mcp" BRIEFING_LEAN_CREDENTIALS="$T/cred-nourl.json"; rc=$?
[ $rc = 0 ] && ok "BRIEFING_LEAN_PORTAL_URL gives the address when the login entry has none" || bad "url from setting: rc=$rc $(cat "$T/err")"
mkcred "$T/cred-down.json" 3600 "$TOKEN" 1; BRIEFING_LEAN_TIMEOUT=20 fetch BRIEFING_LEAN_CREDENTIALS="$T/cred-down.json"; rc=$?
[ $rc = 4 ] && one_err && ok "a portal that cannot be reached: exit 4" || bad "unreachable: rc=$rc $(cat "$T/err")"

# the token's 15-minute life: stale -> the warm command (Claude Code renews its own login) -> read again; never a refresh here
mkcred "$T/cred-old.json" -30; : > "$T/warm-ran"
fetch BRIEFING_LEAN_CREDENTIALS="$T/cred-old.json" BRIEFING_LEAN_WARM_CMD="bash -c 'echo ran >> $T/warm-ran'"; rc=$?
[ $rc = 3 ] && one_err && grep -q 'expired' "$T/err" && [ "$(wc -l < "$T/warm-ran")" = 1 ] && ok "an expired token and a warm command that renews nothing: the warm command ran once, then exit 3 (no refresh of its own)" || bad "expired: rc=$rc ran=$(wc -l < "$T/warm-ran") $(cat "$T/err")"
cat > "$T/warm.sh" <<EOF
#!/usr/bin/env bash
python3 -I - "$T/cred-old.json" "$TOKEN" "$PORT" <<'PY'
import json, sys, time
f, tok, port = sys.argv[1:4]
d = json.load(open(f)); e = d["mcpOAuth"]["mcp-portal|abc"]; e["expiresAt"] = int((time.time() + 900) * 1000); json.dump(d, open(f, "w"))
PY
echo ran >> "$T/warm-ran"
EOF
: > "$T/warm-ran"
fetch BRIEFING_LEAN_CREDENTIALS="$T/cred-old.json" BRIEFING_LEAN_WARM_CMD="bash $T/warm.sh"; rc=$?
[ $rc = 0 ] && [ "$(wc -l < "$T/warm-ran")" = 1 ] && ok "an expired token and a warm command that renews it: the fetch goes on with the renewed login" || bad "warm: rc=$rc $(cat "$T/err")"
: > "$T/warm-ran"; mkcred "$T/cred-fresh.json" 600
fetch BRIEFING_LEAN_CREDENTIALS="$T/cred-fresh.json" BRIEFING_LEAN_WARM_CMD="bash $T/warm.sh"; [ ! -s "$T/warm-ran" ] && ok "a token with 10 minutes left: the warm command is not run" || bad "warm ran for a fresh token"
python3 -I - "$D/gmail_fetch.py" <<'PY' && ok "the portal's edge refuses Python's default user agent (edge error 1010): the fake does too, and the fetch sends its own" || bad "user agent"
import re, sys
src = open(sys.argv[1]).read()
assert 'USER_AGENT = CLIENT_NAME + "/1"' in src and '"User-Agent": USER_AGENT' in src
PY
# the name it gives itself (clientInfo, and with /1 the User-Agent): BRIEFING_LEAN_CLIENT_NAME, else sala-briefing-lean
ua=$(cd "$T" && env -u BRIEFING_LEAN_CLIENT_NAME python3 -I -c 'import importlib.util as u, sys; s = u.spec_from_file_location("gf", sys.argv[1]); m = u.module_from_spec(s); s.loader.exec_module(m); print(m.USER_AGENT, m.CLIENT_NAME)' "$D/gmail_fetch.py")
ua2=$(cd "$T" && BRIEFING_LEAN_CLIENT_NAME=demo-lean python3 -I -c 'import importlib.util as u, sys; s = u.spec_from_file_location("gf", sys.argv[1]); m = u.module_from_spec(s); s.loader.exec_module(m); print(m.USER_AGENT, m.CLIENT_NAME)' "$D/gmail_fetch.py")
[ "$ua" = "sala-briefing-lean/1 sala-briefing-lean" ] && [ "$ua2" = "demo-lean/1 demo-lean" ] && ok "the client name: sala-briefing-lean by default, BRIEFING_LEAN_CLIENT_NAME when set" || bad "client name: '$ua' / '$ua2'"
ro=$(cd "$T" && BRIEFING_GMAIL_CONNECTOR= python3 -I "$D/gmail_fetch.py" 2>&1); rc=$?
[ $rc = 4 ] && case "$ro" in *"BRIEFING_GMAIL_CONNECTOR is not set"*) true;; *) false;; esac && ok "no connector word: the fetch refuses before it reads anything" || bad "no connector (rc=$rc): $ro"

# ---------------------------------------------------------------------------------------------------- part 2
cat > "$T/bin/fetch" <<'EOF'
#!/usr/bin/env bash
# a stand-in for gmail_fetch.py: FETCH_MODE ok | auth | fail | noreads | emptythreads | nokey | fewempty | slow-secret
mf=""; while [ $# -gt 0 ]; do [ "$1" = --meta-file ] && mf=$2; shift; done
echo x >> "$FAKE_DIR/fetch-ran"
case "$FETCH_MODE" in
  auth) echo 'gmail_fetch: the portal refused the login (HTTP 401)' >&2; exit 3 ;;
  fail) echo 'gmail_fetch: the portal was not reached (URLError)' >&2; exit 4 ;;
  noreads) echo '{"unread": 0, "reads": 0, "empty": 0}' > "$mf"; printf '<unread-mail-data unread="0">\n(no unread mail)\n</unread-mail-data>\n'; exit 0 ;;
esac
case "$FETCH_MODE" in   # the reads happened (reads > 0) but the mail did not come back: an early run's case
  emptythreads) echo '{"unread": 10, "more": false, "threads": 10, "shown": 10, "omitted": 0, "reads": 3, "empty": 3, "chars": 321}' > "$mf" ;;
  nokey) echo '{"unread": 7, "more": false, "threads": 6, "shown": 5, "omitted": 1, "reads": 2, "chars": 321}' > "$mf" ;;
  fewempty) echo '{"unread": 10, "more": false, "threads": 10, "shown": 10, "omitted": 0, "reads": 3, "empty": 1, "chars": 321}' > "$mf" ;;
  *) echo '{"unread": 7, "more": false, "threads": 6, "shown": 5, "omitted": 1, "reads": 2, "empty": 0, "chars": 321}' > "$mf" ;;
esac
printf '<unread-mail-data unread="7" threads="6" shown="5" omitted="1">\n[1] thread=18c0b00000000001 kind=human unread_in_thread=1\nFrom: A\nDate: Wed Oct 21st 05:15\nSubject: s\nBody: b\n</unread-mail-data>\n'
EOF
cat > "$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo x >> "$FAKE_DIR/claude-ran"
printf '%s\0' "$@" > "$FAKE_DIR/argv0"; cat > "$FAKE_DIR/stdin"
env | grep -E '^(CLAUDE_CODE_USE_BEDROCK|AWS_REGION|CLAUDE_CONFIG_DIR)=' | sort > "$FAKE_DIR/env"
case "${CLAUDE_MODE:-ok}" in
  fail) echo 'claude: boom' >&2; exit 1 ;;
  noreply) printf '%s' '{"type":"result","subtype":"success","is_error":false,"result":"NO_REPLY","usage":{"input_tokens":5,"output_tokens":2}}'; exit 0 ;;
  chatter) printf '%s' '{"type":"result","subtype":"success","is_error":false,"result":"I could not find any mail.","usage":{"input_tokens":5,"output_tokens":2}}'; exit 0 ;;
esac
python3 - <<'PY'
import json
res = ("*☀️ Good morning, Quill!* — morning email summary\n_As of @@ASOF@@ · @@UNREAD@@ unread · 1 actionable_\n\n"
       "One item needs a reply.\n\n━━━━━━━━━━━━━━\n*🔴 Needs attention today*\n\n*Alex Kim* — Wed Oct 21st 05:15 [gmail:18c0b00000000001]\n    • review the contract\n    • *Action:* reply")
if __import__("os").environ.get("CLAUDE_MODE") == "wrongcount":
    res = res.replace("@@UNREAD@@", "99").replace("@@ASOF@@", "2000-01-01 01:00 AM UTC")
print(json.dumps({"type": "result", "subtype": "success", "is_error": False, "result": res, "duration_ms": 4200, "num_turns": 1,
                  "usage": {"input_tokens": 12, "cache_creation_input_tokens": 3000, "cache_read_input_tokens": 500, "output_tokens": 410},
                  "modelUsage": {"claude-sonnet-5-5": {}}, "total_cost_usd": 0.01}))
PY
EOF
chmod +x "$T/bin/fetch" "$T/bin/claude"
# a webhook listener that counts posts, so "posts nothing" and "posts once" are measured, not assumed
python3 - "$T/hook-port" "$T/hook-seen" <<'PY' &
import http.server, sys
port_file, seen = sys.argv[1:3]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        open(seen, "a").write(self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode() + "\n")
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
    def log_message(self, *a): pass
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H); open(port_file, "w").write(str(s.server_address[1])); s.serve_forever()
PY
HOOK=$!
for _ in $(seq 50); do [ -s "$T/hook-port" ] && break; sleep 0.1; done
printf 'http://127.0.0.1:%s/\n' "$(cat "$T/hook-port")" > "$T/webhook"
DATE=$(TZ=UTC date +%Y%m%d)   # the default zone: BRIEFING_TZ is unset in these runs
export SALA_OWNER_NAME=Quill   # a made-up owner name: the prompt's {{OWNER}} and the greeting come from this setting
lean() { # lean [VAR=val …] -- [args]: runs summary-lean.sh with the stubs; the output in $T/run
    rm -rf "$T/logs"; mkdir -p "$T/logs"; rm -f "$T/hook-seen" "$T/fetch-ran" "$T/claude-ran" "$T/argv0" "$T/stdin" "$T/env"
    local envs=(); while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done; [ "${1:-}" = -- ] && shift
    env HOME="$T/home" FAKE_DIR="$T" FETCH_MODE=ok BRIEFING_LOGDIR="$T/logs" BRIEFING_CLAUDE_BIN="$T/bin/claude" BRIEFING_LEAN_FETCH_CMD="$T/bin/fetch" \
        BRIEFING_WEBHOOK_FILE="$T/webhook" BRIEFING_BACKEND=cli BRIEFING_SESSIONS_CMD=true BRIEFING_BOARD_DIR="$T/no-board" BRIEFING_COMMIT_REPOS= \
        BRIEFING_HOLDS_CMD="${HOLDS_STUB:-true}" BRIEFING_LEAN_RETRY_WAIT=0 ${envs[@]+"${envs[@]}"} "$D/summary-lean.sh" "$@" > "$T/run" 2>&1
}
posts() { [ -f "$T/hook-seen" ] && wc -l < "$T/hook-seen" || echo 0; }
OUTF() { echo "$T/logs/lean/$DATE.txt"; }

# default mode: file, no post
lean --; rc=$?
[ $rc = 0 ] && [ -s "$(OUTF)" ] && head -1 "$(OUTF)" | grep -qF '*☀️ Good morning, Quill!* — morning email summary' && [ "$(posts)" = 0 ] \
    && ok "default: the digest is written to lean/YYYYMMDD.txt and NOTHING is posted (side by side)" || bad "default: rc=$rc posts=$(posts) $(cat "$T/run")"
sed -n 2p "$(OUTF)" | grep -qE '^_As of (Mon|Tue|Wed|Thu|Fri|Sat|Sun) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) [0-9]{1,2}(st|nd|rd|th) [0-9]{2}:[0-9]{2} UTC · 7 unread · 1 actionable_$' \
    && ok "count line: the time and the unread count come from code (7), the model only supplied 'M actionable'" || bad "count line: $(sed -n 2p "$(OUTF)")"
lean CLAUDE_MODE=wrongcount --; sed -n 2p "$(OUTF)" | grep -q '· 7 unread ·' && ! sed -n 2p "$(OUTF)" | grep -q '99\|2000' \
    && ok "count line: a count the model wrote itself is overwritten with the fetched one" || bad "wrong count kept: $(sed -n 2p "$(OUTF)")"
u=$(cat "$T/logs/lean/$DATE.usage")
printf '%s\n' "$u" | grep -q '^input_tokens=3512 (new 12, cache write 3000, cache read 500) output_tokens=410 seconds=[0-9]* model_seconds=4.2 model=claude-sonnet-5-5 unread=7 ' \
    && ok "usage line: input/output tokens, seconds and the mail size, in lean/YYYYMMDD.usage" || bad "usage: $u"
lean --; grep -q 'wrote .*not posted' "$T/run" && ok "default: the run says where the text went and that it was not posted" || bad "run output: $(cat "$T/run")"

# the model call
tr '\0' '\n' < "$T/argv0" > "$T/argv"
exp=$'-p\n--tools\n\n--strict-mcp-config\n--setting-sources\n\n--disable-slash-commands\n--system-prompt'
[ "$(head -8 "$T/argv")" = "$exp" ] && sed -n '9,$p' "$T/argv" | grep -qxF -- '--no-session-persistence' && grep -qxF -- '--output-format' "$T/argv" && grep -qxF json "$T/argv" \
    && ok "model call: claude -p --tools \"\" --strict-mcp-config --setting-sources \"\" --disable-slash-commands --system-prompt … --no-session-persistence --output-format json" || bad "argv: $(head -20 "$T/argv")"
grep -qE '^--(allowedTools|settings|mcp-config|allowed-tools|dangerously)' "$T/argv" && bad "a tool, hook or MCP flag is on the model call" || ok "model call: no tools, no MCP, no settings, no guard hook flag"
[ "$(tr '\0' '\n' < "$T/argv0" | grep -c .)" -gt 0 ] && grep -qxF -- '--model' "$T/argv" && [ "$(grep -A1 -x -- '--model' "$T/argv" | tail -1)" = sonnet ] && ok "model call: --model is lib.sh's MODEL (sonnet by default)" || bad "model flag: $(grep -A1 -x -- '--model' "$T/argv")"
lean SALA_BRIEFING_MODEL=haiku --; [ "$(tr '\0' '\n' < "$T/argv0" | grep -A1 -x -- '--model' | tail -1)" = haiku ] && ok "model call: SALA_BRIEFING_MODEL moves the model (the variable lib.sh uses)" || bad "SALA_BRIEFING_MODEL"
sp=$(python3 -I -c 'import sys;a=open(sys.argv[1],"rb").read().split(b"\0");print(a[a.index(b"--system-prompt")+1].decode(),end="")' "$T/argv0")
[ "$sp" = "$(sed -e "s/{{OWNER}}/Quill/g" -e "s/{{GREETING}}/, Quill/g" -e "s/{{WATCHLIST}}/none configured/g" -e "s/{{LOW_PRIORITY_SENDERS}}/none configured/g" "$D/summary-lean.prompt.md")" ] && ok "model call: the system prompt is summary-lean.prompt.md, whole, its placeholders filled from the settings (owner name; the empty lists read \"none configured\")" || bad "system prompt differs"
case "$sp" in *'{{'*) bad "the system prompt keeps a placeholder" ;; *"Quill's Gmail"*"Good morning, Quill!"*) ok "system prompt: the owner's name and the greeting are the setting's" ;; *) bad "system prompt lacks the owner's name" ;; esac
lean SALA_OWNER_NAME= --; sp0=$(python3 -I -c 'import sys;a=open(sys.argv[1],"rb").read().split(b"\0");print(a[a.index(b"--system-prompt")+1].decode(),end="")' "$T/argv0")
case "$sp0" in *'{{'*|*Quill*) bad "no name set: the prompt keeps a placeholder or a stale name" ;; *"the owner's Gmail"*'Good morning!'*) ok "no name set: the prompt says the owner and a plain greeting" ;; *) bad "no name set: $(printf '%s' "$sp0" | head -c 200)" ;; esac
[ -s "$(OUTF)" ] && ok "no name set: the greeting check wants only 'Good morning', so the digest is still delivered" || bad "no name set: no digest"
grep -qx '<unread-mail-data unread="7" threads="6" shown="5" omitted="1">' "$T/stdin" && grep -q '^Current local time: ' "$T/stdin" && grep -q 'thread=18c0b00000000001' "$T/stdin" \
    && ok "model call: the trimmed mail, thread ids included, and the local time are on stdin" || bad "stdin: $(head -5 "$T/stdin")"
HOLDS_STUB="$T/bin/holds" ; printf '#!/usr/bin/env bash\nprintf "%%s\\n" "<new-holds-data>" "- board#9001 one" "</new-holds-data>"\n' > "$T/bin/holds"; chmod +x "$T/bin/holds"
lean --; grep -qx -- '- board#9001 one' "$T/stdin" && [ "$(grep -n '^<new-holds-data>' "$T/stdin" | cut -d: -f1)" -gt "$(grep -n '^</unread-mail-data>' "$T/stdin" | cut -d: -f1)" ] \
    && ok "new holds: fetch_new_holds' block follows the mail block on stdin, as in summary.sh" || bad "holds block: $(cat "$T/stdin" | tail -5)"
HOLDS_STUB=
lean --; ! grep -q 'new-holds-data' "$T/stdin" && ok "new holds: none, no block" || bad "holds block when none"
lean CLAUDE_CODE_USE_BEDROCK=1 AWS_REGION=us-east-1 --; grep -qx 'CLAUDE_CODE_USE_BEDROCK=1' "$T/env" && grep -qx 'AWS_REGION=us-east-1' "$T/env" \
    && ok "lane: a Bedrock lane's variables on the launch line reach the model call unchanged (nothing is unset or pinned to Max)" || bad "env: $(cat "$T/env")"
lean BRIEFING_CLAUDE_CONFIG_DIR="$T/cfg" --; grep -qx "CLAUDE_CONFIG_DIR=$T/cfg" "$T/env" && ok "lane: BRIEFING_CLAUDE_CONFIG_DIR still picks the login, as in the other briefings" || bad "config dir: $(cat "$T/env")"
for pf in summary defunct; do   # the other two prompts take the same placeholders through briefing_prompt
    pt=$(env HOME="$T/home" BRIEFING_LOGDIR="$T/logs" SALA_OWNER_NAME=Quill BRIEFING_FORWARD_LABEL=forwarded bash -c '. "$1/lib.sh"; briefing_prompt "$1/$2.prompt.md"' _ "$D" "$pf" 2>/dev/null)
    case "$pt" in *'{{'*) bad "$pf.prompt.md keeps a placeholder" ;; *"Quill's"*) ok "$pf.prompt.md: {{OWNER}} is the setting's name, no placeholder is left" ;; *) bad "$pf.prompt.md: no owner name in: $(printf '%s' "$pt" | head -c 120)" ;; esac
done
# the lists and the label are settings: unset they read "none configured" / nothing shipped; set they fill the prompts (an & in a value stays an &)
lean BRIEFING_WATCHLIST='Acme Labs, Foo Corp & Co' BRIEFING_LOW_PRIORITY_SENDERS='news@example.com, promo@example.org' --
spw=$(python3 -I -c 'import sys;a=open(sys.argv[1],"rb").read().split(b"\0");print(a[a.index(b"--system-prompt")+1].decode(),end="")' "$T/argv0")
case "$spw" in *'{{'*) bad "watchlist set: a placeholder is left" ;; *'(Acme Labs, Foo Corp & Co)'*'news@example.com, promo@example.org'*) ok "settings: BRIEFING_WATCHLIST and BRIEFING_LOW_PRIORITY_SENDERS fill the prompt (the & stays an &)" ;; *) bad "settings: lists not in the prompt" ;; esac
case "$sp0" in *'(none configured)'*) ok "settings: an unset watchlist reads 'none configured', nothing real is shipped" ;; *) bad "unset watchlist: no neutral default" ;; esac
env HOME="$T/home" BRIEFING_LOGDIR="$T/logs" bash -c '. "$1/lib.sh"; briefing_need_label defunct' _ "$D" 2>/dev/null; [ $? = 1 ] \
    && ok "settings: no BRIEFING_FORWARD_LABEL means no defunct digest (briefing_need_label refuses, defunct.sh exits 0)" || bad "need_label without a label"
env HOME="$T/home" BRIEFING_LOGDIR="$T/logs" BRIEFING_FORWARD_LABEL='fwd/old' bash -c '. "$1/lib.sh"; briefing_need_label defunct' _ "$D" 2>/dev/null \
    && ok "settings: BRIEFING_FORWARD_LABEL set: the defunct digest is on" || bad "need_label with a label"
env HOME="$T/home" BRIEFING_LOGDIR="$T/logs" BRIEFING_FORWARD_LABEL='bad label"x' bash -c '. "$1/lib.sh"; briefing_need_label defunct' _ "$D" 2>/dev/null; [ $? = 1 ] \
    && ok "settings: a label with a space or a quote is refused, never put into a prompt" || bad "need_label accepted a bad label"
# the zone is a setting too: UTC unless BRIEFING_TZ names one
[ "$(env HOME="$T/home" BRIEFING_LOGDIR="$T/logs" bash -c '. "$1/lib.sh"; now_local' _ "$D" | grep -c ' UTC$')" = 1 ] && [ "$(env HOME="$T/home" BRIEFING_LOGDIR="$T/logs" BRIEFING_TZ=Etc/GMT-4 bash -c '. "$1/lib.sh"; now_local' _ "$D" | grep -c '+04$')" = 1 ] \
    && ok "settings: the zone is UTC by default and BRIEFING_TZ moves it (lib.sh's now_local and the exported TZ)" || bad "BRIEFING_TZ"
grep -q 'mcp__\|codemode\|portal_codemode\|ToolSearch' "$D/summary-lean.prompt.md" && bad "the system prompt still talks of connectors or portal tools" || ok "system prompt: no connector, portal or tool wording left"
grep -q '@@ASOF@@' "$D/summary-lean.prompt.md" && grep -q '@@UNREAD@@' "$D/summary-lean.prompt.md" && grep -q 'new-holds-data' "$D/summary-lean.prompt.md" && grep -q '\[gmail:THREAD_ID\]' "$D/summary-lean.prompt.md" && grep -q 'NEVER return `NO_REPLY`' "$D/summary-lean.prompt.md" \
    && ok "system prompt: keeps the output rules (placeholders for the count line, holds, the gmail marker, always deliver)" || bad "system prompt lost a rule"

# posting
lean -- --post; rc=$?
[ $rc = 0 ] && [ "$(posts)" = 1 ] && grep -q 'morning email summary' "$T/hook-seen" && grep -q 'open' "$T/hook-seen" && [ ! -e "$(OUTF)" ] \
    && ok "--post: delivered once to the webhook through post_slack (the [gmail:] marker linked), no file" || bad "--post: rc=$rc posts=$(posts) $(cat "$T/run")"
lean BRIEFING_LEAN_POST=1 --; [ "$(posts)" = 1 ] && ok "BRIEFING_LEAN_POST=1 is --post" || bad "BRIEFING_LEAN_POST: posts=$(posts)"
lean BRIEFING_LEAN_POST=1 BRIEFING_NO_POST=1 --; [ "$(posts)" = 0 ] && grep -q 'morning email summary' "$T/logs/would-post.log" && ok "--post honours BRIEFING_NO_POST (to would-post.log), like the other briefings" || bad "NO_POST: posts=$(posts)"
lean -- --bogus; [ $? = 2 ] && [ ! -e "$T/claude-ran" ] && ok "an unknown argument is refused (exit 2) before anything runs" || bad "bogus argument"

# failures: loud, never a digest, the model never called
for mode in auth fail noreads emptythreads nokey; do
    case $mode in auth) want="didn't run"; why='the portal login for Gmail was refused or has expired: gmail_fetch: the portal refused the login (HTTP 401)' ;;
        fail) want="failed"; why='the mail could not be read (exit 4): gmail_fetch: the portal was not reached (URLError)' ;;
        noreads) want="held back"; why='it was written without reading Gmail once, so it could be made up; not delivered' ;;
        emptythreads) want="held back"; why='Gmail came back with empty threads (3 of 10 have no subject and no sender); not delivered' ;;
        nokey) want="held back"; why='the mail reader did not say how many threads came back empty, so they could not be checked; not delivered' ;; esac
    lean FETCH_MODE=$mode --; rc=$?
    f=$(cat "$(OUTF)" 2>/dev/null)
    [ $rc = 1 ] && printf '%s\n' "$f" | head -1 | grep -qF "🚨 *Morning Email Summary (lean) $want*" && printf '%s\n' "$f" | grep -qF "$why" && [ ! -e "$T/claude-ran" ] \
        && ! printf '%s\n' "$f" | grep -q 'Good morning' && [ "$(posts)" = 0 ] \
        && ok "default, fetch $mode: exit 1, the 🚨 '$want' notice in the file, no digest, the model never called, nothing posted" || bad "fetch $mode: rc=$rc ran=$(wc -l < "$T/claude-ran" 2>/dev/null) f=$f"
    lean FETCH_MODE=$mode -- --post; rc=$?
    [ $rc = 1 ] && [ "$(posts)" = 1 ] && grep -qF "*Morning Email Summary $want*" "$T/hook-seen" && ! grep -q 'Good morning' "$T/hook-seen" && [ ! -e "$T/claude-ran" ] \
        && ok "--post, fetch $mode: the same notice posted once, titled like summary.sh's, no digest" || bad "--post fetch $mode: rc=$rc posts=$(posts) $(cat "$T/hook-seen" 2>/dev/null | cut -c1-200)"
done
lean FETCH_MODE=auth BRIEFING_GMAIL_ACCOUNT=alex@example.com --
grep -qF 'the portal login for Gmail (alex@example.com) was refused' "$(OUTF)" 2>/dev/null \
    && ok "BRIEFING_GMAIL_ACCOUNT set: the login notice names the account" || bad "account notice: $(cat "$(OUTF)" 2>/dev/null | cut -c1-200)"
for mode in fail noreply chatter; do
    lean CLAUDE_MODE=$mode -- --post; rc=$?
    [ $rc = 1 ] && [ "$(posts)" = 1 ] && grep -qF '*Morning Email Summary failed*' "$T/hook-seen" && ! grep -q 'Good morning, Quill' "$T/hook-seen" \
        && ok "the model call ends as '$mode': a 🚨 failed notice, not a digest" || bad "claude $mode: rc=$rc posts=$(posts) $(cut -c1-200 "$T/hook-seen" 2>/dev/null)"
done
lean FETCH_MODE=fewempty --; rc=$?
[ $rc = 0 ] && grep -q 'Good morning, Quill' "$(OUTF)" && ok "one empty thread of ten (under a fifth) does not stop the digest" || bad "fewempty: rc=$rc"
lean CLAUDE_MODE=fail --; [ "$(wc -l < "$T/claude-ran")" = 2 ] && ok "a failed model call is retried once" || bad "retries: $(wc -l < "$T/claude-ran")"
grep -rq "$TOKEN" "$T/logs" "$T/run" 2>/dev/null && bad "the token is in a log" || ok "no secret in the logs or the run output"

# lean-compare.sh
rm -rf "$T/logs"; mkdir -p "$T/logs/lean"
printf '%s\n' '{"type":"result","result":"OLD DIGEST TEXT","num_turns":9,"duration_ms":123000,"usage":{"input_tokens":50,"cache_read_input_tokens":1000,"output_tokens":700}}' > "$T/logs/summary.20261022.jsonl"
printf 'NEW DIGEST TEXT\n' > "$T/logs/lean/20261022.txt"; printf 'input_tokens=1 output_tokens=2\n' > "$T/logs/lean/20261022.usage"
out=$(HOME="$T/home" BRIEFING_LOGDIR="$T/logs" "$D/lean-compare.sh" 20261022 2>&1)
printf '%s\n' "$out" | grep -q '^=== OLD' && printf '%s\n' "$out" | grep -q '^OLD DIGEST TEXT$' && printf '%s\n' "$out" | grep -q 'old run: turns=9 seconds=123.0 input_tokens=1050 output_tokens=700' \
    && printf '%s\n' "$out" | grep -q '^=== NEW' && printf '%s\n' "$out" | grep -q '^NEW DIGEST TEXT$' && printf '%s\n' "$out" | grep -q 'new run: input_tokens=1 output_tokens=2' \
    && ok "lean-compare.sh: the day's old text (from the summary log) and new text, each with its usage" || bad "compare: $out"
out=$(HOME="$T/home" BRIEFING_LOGDIR="$T/logs" "$D/lean-compare.sh" 20250101 2>&1); printf '%s\n' "$out" | grep -q '(no such log)' && printf '%s\n' "$out" | grep -q '(no such file)' && ok "lean-compare.sh: a day with neither says so" || bad "compare empty: $out"
HOME="$T/home" BRIEFING_LOGDIR="$T/logs" "$D/lean-compare.sh" 2026-10-22 >/dev/null 2>&1; [ $? = 2 ] && ok "lean-compare.sh: a date that is not YYYYMMDD is refused" || bad "compare bad date"

# files and units
for f in summary-lean.sh lean-compare.sh gmail_fetch.py; do [ -x "$D/$f" ] && ok "$f is executable" || bad "$f is not executable"; done
bash -n "$D/summary-lean.sh" && bash -n "$D/lean-compare.sh" && python3 -I -c 'import ast,sys;ast.parse(open(sys.argv[1]).read())' "$D/gmail_fetch.py" && ok "bash -n and a Python parse of the three scripts" || bad "syntax"
U=$D/systemd; s=$U/sala-briefing-summary-lean.service; t=$U/sala-briefing-summary-lean.timer
grep -qxF 'OnCalendar=*-*-* 06:00:00 UTC' "$t" && grep -qxF 'Persistent=true' "$t" && grep -qxF 'ExecStart=%h/.local/bin/salamander lane exec bedrock -- %h/salamander/contrib/briefing/summary-lean.sh --post' "$s" \
    && grep -qxF 'X-Model-Lane=bedrock' "$s" \
    && grep -q '^Description=.*posts the morning email summary to #briefing' "$s" \
    && ok "units: the lean service runs summary-lean.sh --post and its Description says it posts to #briefing; the timer fires at 06:00 UTC" || bad "lean units"
for line in 'Environment=BRIEFING_BACKEND=cli' 'Environment=BRIEFING_CLAUDE_CONFIG_DIR=' 'UnsetEnvironment=ANTHROPIC_API_KEY ANTHROPIC_CUSTOM_HEADERS'; do grep -qxF "$line" "$s" || bad "lean service lacks: $line"; done
if command -v systemd-analyze >/dev/null 2>&1; then
    mkdir -p "$T/u" "$T/cache"; for f in "$s" "$t"; do sed -e "s#%h/.local/bin/salamander#$ROOT/bin/salamander#g" -e "s#%h/salamander#$ROOT#g" "$f" > "$T/u/$(basename "$f")"; done
    out=$(systemd-analyze verify "$T"/u/* 2>&1); rc=$?; ours=$(printf '%s\n' "$out" | grep 'sala-briefing' || true)
    if [ $rc = 0 ] && [ -z "$ours" ]; then ok "systemd-analyze verify of the lean pair"
    elif printf '%s\n' "$out" | grep -qiE 'failed to (connect|initialize)|no such file or directory.*/run/systemd|not been booted'; then echo "  skip systemd-analyze verify (no usable systemd here)"
    elif [ -z "$ours" ] && printf '%s\n' "$out" | grep -qiE "failed to create directory '?/run/systemd"; then echo "  skip systemd-analyze verify (unprivileged on a box not booted by systemd, as the WSL2 CI runner: it cannot create /run/systemd)"
    else bad "systemd-analyze verify rc=$rc: $out"; fi
fi
exit $fail
