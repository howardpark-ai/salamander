#!/bin/bash
# Prints the day's two morning digests one after the other: OLD = the text summary.sh produced (the result of the
# day's summary stream log, summary.<YYYYMMDD>.jsonl, plus its turns / seconds / tokens), NEW = what summary-lean.sh wrote
# (lean/<YYYYMMDD>.txt and its usage line). Posts nothing, calls nothing.
# Usage: lean-compare.sh [YYYYMMDD]      (default: today, in BRIEFING_TZ)
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/lib.sh"   # sets BRIEFING_DIR, LOGDIR

D=${1:-$(date +%Y%m%d)}
case "$D" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;; *) echo "lean-compare.sh: the date is YYYYMMDD" >&2; exit 2 ;; esac

echo "=== OLD: summary.sh, $LOGDIR/summary.$D.jsonl ==="
if [ -r "$LOGDIR/summary.$D.jsonl" ]; then
  python3 -I - "$LOGDIR/summary.$D.jsonl" <<'PY'
import json, sys
res, last = "", {}
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    try: d = json.loads(line)
    except Exception: continue
    if isinstance(d, dict) and d.get("type") == "result":
        res, last = d.get("result") or "", d
print(res.strip() or "(the log has no result)")
u = last.get("usage") or {}
print("--\nold run: turns=%s seconds=%s input_tokens=%s output_tokens=%s" % (
    last.get("num_turns", "?"), round((last.get("duration_ms") or 0) / 1000, 1),
    sum(int(u.get(k) or 0) for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")), u.get("output_tokens", "?")))
PY
else
  echo "(no such log)"
fi
echo
echo "=== NEW: summary-lean.sh, $LOGDIR/lean/$D.txt ==="
if [ -r "$LOGDIR/lean/$D.txt" ]; then
  cat "$LOGDIR/lean/$D.txt"
  [ -r "$LOGDIR/lean/$D.usage" ] && printf -- '--\nnew run: %s\n' "$(cat "$LOGDIR/lean/$D.usage")"
else
  echo "(no such file)"
fi
