#!/bin/bash
# Morning Email Summary, the lean way. Lives in salamander contrib/briefing/ beside summary.sh, which it will
# replace once the owner has compared the two. CODE reads the unread mail (gmail_fetch.py: the portal's Gmail reads over MCP
# HTTP, trimmed in code) and ONE model call with no tools, no MCP and no settings writes the text from it:
#   claude -p --tools "" --strict-mcp-config --setting-sources "" --disable-slash-commands --system-prompt <summary-lean.prompt.md, its {{OWNER}} and {{GREETING}} filled from SALA_OWNER_NAME>
#          --no-session-persistence --output-format json --model $MODEL     (the mail on stdin)
# The model can touch nothing, so the read guard (guard.py) is not on it; it is applied to the code's own reads instead.
#
# Usage: summary-lean.sh [--post]      (env BRIEFING_LEAN_POST=1 is the same)
#   default (side by side with summary.sh): the digest goes to $LOGDIR/lean/YYYYMMDD.txt, a usage line to YYYYMMDD.usage,
#     and NOTHING is posted, so the owner does not get two digests. A failure writes its notice to the same file.
#   --post: delivers like summary.sh, to the briefing channel through post_slack, a failure as the same kind of 🚨 notice.
# Lane: nothing here is tied to one plan. The model is $MODEL from lib.sh (SALA_BRIEFING_MODEL, default sonnet); the call inherits the
# caller's environment, so Bedrock (CLAUDE_CODE_USE_BEDROCK, AWS_*) on the launch line or a drop-in works unchanged.
# The delivery guard stays: a digest exists only if gmail_fetch.py really read Gmail (its meta file counts the reads); a
# failed or refused read is a loud notice, never a digest.
. "$(_s=${BASH_SOURCE[0]}; [ -L "$_s" ] && _s=$(readlink -f "$_s"); [[ $_s == */* ]] || _s=./$_s; cd -P "${_s%/*}" && pwd -P)/lib.sh"   # sets BRIEFING_DIR (no dirname/readlink process unless the script is a symlink)

POST=0
[ "${BRIEFING_LEAN_POST-}" = 1 ] && POST=1
for a in "$@"; do
  case "$a" in
    --post) POST=1 ;;
    -h|--help) awk 'NR==1{next} /^#/{print; next} {exit}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "summary-lean.sh: unknown argument $a" >&2; exit 2 ;;
  esac
done

briefing_need_connector summary-lean || exit 0   # no connector set: the lean summary is off
LEANDIR=$LOGDIR/lean; [ -d "$LEANDIR" ] || mkdir -p "$LEANDIR"
printf -v DATE '%(%Y%m%d)T' -1
OUT=$LEANDIR/$DATE.txt; USAGE=$LEANDIR/$DATE.usage
JSON=$LOGDIR/summary-lean.$DATE.json; ERRLOG=$LOGDIR/summary-lean.$DATE.err
if [ "$POST" = 1 ]; then TITLE="Morning Email Summary"; else TITLE="Morning Email Summary (lean)"; fi
WORK=$(mktemp -d "$LOGDIR/lean.XXXXXX") || exit 1; chmod 700 "$WORK"; trap 'rm -rf "$WORK"' EXIT
printf -v START '%(%s)T' -1
: > "$ERRLOG"; rm -f "$USAGE"

# lean_emit <text>  — where the finished text goes: the file by default, Slack with --post. Always goes through here, so a
# notice and a digest are handled alike and the default run can never post.
lean_emit() {
  if [ "$POST" = 1 ]; then post_slack "$1" >/dev/null
  else printf '%s\n' "$1" > "$WORK/out" && mv -f "$WORK/out" "$OUT"; echo "summary-lean: wrote $OUT (not posted)"; fi
}
# lean_fail <headline> <bullet> — the 🚨 notice of deliver (lib.sh): the mail was not read or the text was not written.
lean_fail() {
  cron_log "summary-lean: $1: $2"
  lean_emit "🚨 *$TITLE $1*
    • $2
    • Details: $ERRLOG on $(briefing_box)"
  exit 1
}

fetch_new_holds   # as summary.sh: stackshot's new holds (holds.py), '' when none or on a failure

# --- 1. code reads the mail ---
FETCH=(python3 -I "$BRIEFING_DIR/gmail_fetch.py")
PORTAL_URL=$(briefing_setting BRIEFING_LEAN_PORTAL_URL)   # the portal's address: the environment, else the sala config line, else the login entry's
[ -n "$PORTAL_URL" ] && export BRIEFING_LEAN_PORTAL_URL=$PORTAL_URL
[ -n "${BRIEFING_LEAN_FETCH_CMD-}" ] && read -ra FETCH <<< "$BRIEFING_LEAN_FETCH_CMD"
timeout "${BRIEFING_LEAN_FETCH_CAP:-300}" "${FETCH[@]}" --meta-file "$WORK/meta.json" > "$WORK/mail" 2> "$WORK/fetch.err" </dev/null; FRC=$?
cat "$WORK/fetch.err" >> "$ERRLOG"
REASON=$(grep -v '^\s*$' "$WORK/fetch.err" | tail -1 | cut -c1-200)
case $FRC in
  0) ;;
  3) ACCT=$(briefing_setting BRIEFING_GMAIL_ACCOUNT)
     lean_fail "didn't run" "the portal login for Gmail${ACCT:+ ($ACCT)} was refused or has expired: ${REASON:-no reason given}" ;;
  *) lean_fail "failed" "the mail could not be read (exit $FRC): ${REASON:-no reason given}" ;;
esac
# The meta file's numbers, read by ONE python start (it was nine), each as META_<key> (empty when absent or unreadable).
META_KEYS=(reads unread more empty threads shown omitted chars)
meta_load() {
  local k v i=0
  for k in "${META_KEYS[@]}"; do printf -v "META_$k" ''; done
  while IFS= read -r -d '' v; do printf -v "META_${META_KEYS[i]}" '%s' "$v"; i=$((i + 1)); done < <(python3 -I -c 'import json,sys
try: d = json.load(open(sys.argv[1]))
except Exception: d = None
for k in sys.argv[2:]:
    try: v = str(d.get(k, ""))
    except Exception: v = ""
    sys.stdout.write(v.rstrip("\n") + "\0")' "$WORK/meta.json" "${META_KEYS[@]}")
}
meta_load
READS=$META_reads; UNREAD=$META_unread; MORE=$META_more
[ "${READS:-0}" -gt 0 ] 2>/dev/null && [ -s "$WORK/mail" ] \
  || lean_fail "held back" "it was written without reading Gmail once, so it could be made up; not delivered"
# Second wall behind gmail_fetch.py's own check (exit 4 when Gmail came back with empty threads): the reads happened, but
# did the mail come back? An early run made many reads and got threads with no sender, date, subject
# or body, and the model was told so. meta's "empty" counts the threads with neither subject nor sender; it must be there
# (a fetch that does not report it is not trusted) and may be at most a fifth of the threads.
EMPTY=$META_empty; THREADS=$META_threads
if ! [ "${EMPTY:-x}" -ge 0 ] 2>/dev/null || ! [ "${THREADS:-x}" -ge 0 ] 2>/dev/null; then
  lean_fail "held back" "the mail reader did not say how many threads came back empty, so they could not be checked; not delivered"
fi
[ "$EMPTY" -gt 0 ] && [ $(( EMPTY * 5 )) -gt "$THREADS" ] \
  && lean_fail "held back" "Gmail came back with empty threads ($EMPTY of $THREADS have no subject and no sender); not delivered"
UNREAD_TXT=$UNREAD; [ "$MORE" = True ] && UNREAD_TXT="$UNREAD+"

# --- 2. one model call, nothing to touch ---
{ printf 'Current local time: %s.\n\n' "$(printf '%(%a %b %-d %Y, %H:%M %Z)T' -1)"; cat "$WORK/mail"; [ -n "$HOLDS_BLOCK" ] && printf '\n%s\n' "$HOLDS_BLOCK"; } > "$WORK/prompt"
cfg=(); [ -n "$BRIEFING_CLAUDE_CONFIG_DIR" ] && cfg=("CLAUDE_CONFIG_DIR=$BRIEFING_CLAUDE_CONFIG_DIR")
briefing_owner_load   # the owner's name (SALA_OWNER_NAME) for the prompt's {{OWNER}} and the greeting check below
LEAN_PROMPT=$(briefing_prompt "$BRIEFING_DIR/summary-lean.prompt.md")
lean_model() {
  timeout "${BRIEFING_LEAN_MODEL_CAP:-300}" env ${cfg[@]+"${cfg[@]}"} "$CLAUDE_BIN" -p --tools "" --strict-mcp-config \
      --setting-sources "" --disable-slash-commands --system-prompt "$LEAN_PROMPT" \
      --no-session-persistence --output-format json --model "$MODEL" < "$WORK/prompt" > "$JSON" 2>> "$ERRLOG"
}
lean_model; MRC=$?
if [ "$MRC" -ne 0 ] || ! grep -q '"result"' "$JSON" 2>/dev/null; then   # one retry: a cheap call, a transient failure
  cron_log "summary-lean: the model call failed (exit $MRC); retrying once in 20 s"
  sleep "${BRIEFING_LEAN_RETRY_WAIT:-20}"; lean_model; MRC=$?
fi

# --- 3. the text (placeholders filled by code) and the usage line ---
BRIEFING_DIR="$BRIEFING_DIR" BRIEFING_ECHO_PREFIX="On $(briefing_box) (" python3 -I - "$JSON" "$WORK/result" "$WORK/usage" "$(printf '%(%s)T' -1)" "$UNREAD_TXT" "$(( $(printf '%(%s)T' -1) - START ))" \
    "$META_threads" "$META_shown" "$META_omitted" "$META_chars" <<'PY' 2>> "$ERRLOG"
import importlib.util, json, os, re, sys
from datetime import datetime, timezone
jpath, rpath, upath, now, unread, secs, threads, shown, omitted, chars = sys.argv[1:11]
# the as-of time in the owner's date form (`Mon Oct 26th 14:03 UTC`, in the zone BRIEFING_TZ names), from the same formatter as the mail's dates
_spec = importlib.util.spec_from_file_location("gmail_fetch", os.path.join(os.environ["BRIEFING_DIR"], "gmail_fetch.py"))
_gf = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(_gf)
_t = datetime.fromtimestamp(int(now), timezone.utc)
asof = _gf.fmt_local(_t) + " " + (_t.astimezone().tzname() or "")
try:
    d = json.load(open(jpath, encoding="utf-8"))
except Exception:
    sys.exit(1)
if isinstance(d, list):
    d = next((x for x in reversed(d) if isinstance(x, dict) and x.get("type") == "result"), {})
if not isinstance(d, dict) or d.get("is_error"):
    sys.exit(1)
res = d.get("result") or ""
res = "\n".join(l for l in res.splitlines() if not l.startswith(os.environ["BRIEFING_ECHO_PREFIX"])).strip()   # a CLAUDE.md echo, as run_claude drops it
res = res.replace("@@ASOF@@", asof).replace("@@UNREAD@@", unread)
lines = res.split("\n")
for i, l in enumerate(lines[:4]):   # the count line is code's: whatever time and number the model put there, the real ones win
    if l.startswith("_As of"):
        lines[i] = re.sub(r"^_As of .*? · \d+\+? unread", f"_As of {asof} · {unread} unread", l, count=1)
res = "\n".join(lines)
u = d.get("usage") or {}
new, cw, cr, out = (int(u.get(k) or 0) for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"))
model = next(iter(d.get("modelUsage") or {}), "?")
open(rpath, "w", encoding="utf-8").write(res)
open(upath, "w", encoding="utf-8").write(
    f"input_tokens={new + cw + cr} (new {new}, cache write {cw}, cache read {cr}) output_tokens={out} "
    f"seconds={secs} model_seconds={round((d.get('duration_ms') or 0) / 1000, 1)} model={model} "
    f"unread={unread} threads={threads} shown={shown} omitted={omitted} mail_chars={chars} reply_chars={len(res)}\n")
PY
PRC=$?
RESULT=$(cat "$WORK/result" 2>/dev/null)
[ "$PRC" -ne 0 ] || [ -z "$RESULT" ] && lean_fail "failed" "the model run produced no text (claude exit $MRC)"
case "$RESULT" in NO_REPLY*) lean_fail "failed" "the model run answered NO_REPLY, which this job never sends (claude exit $MRC)" ;; esac
printf '%s' "$RESULT" | grep -qF "Good morning$BRIEFING_GREETING" || lean_fail "failed" "the model's answer is not a digest (it lacks the greeting); not delivered"

# --- 4. deliver: a file by default, Slack with --post ---
cp -f "$WORK/usage" "$USAGE"
lean_emit "$RESULT"
echo "summary-lean: $(cat "$USAGE")"
