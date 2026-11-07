# lib/map.sh — decode the claude.ai/code sidebar: real session name ↔ web session id ↔ tmux.
# The sidebar shows an auto-generated label for a pane whose Remote Control bridge was minted
# fresh (e.g. after an org/account change); this table maps it back. Bridge ids survive
# ordinary recycles and reboots; they change on an org change, a stripped transcript, or a new
# conversation — re-run after those.
#
#   map                 print the table (markdown)
#   map --write PATH    also write it to PATH

OUT=""; [ "${1:-}" = "--write" ] && { OUT="${2:-}"; [ -n "$OUT" ] || die "--write needs a path"; }

rows=$(
  for f in "$SALA_REG_DIR"/*.json; do
    [ -r "$f" ] || continue
    python3 -c '
import json,os,sys,subprocess
p=sys.argv[1]
try: d=json.load(open(p))
except Exception: sys.exit()
pid=os.path.basename(p)[:-5]
try: os.kill(int(pid),0)
except Exception: sys.exit()
if not d.get("tmux"): sys.exit()
tm=d.get("tmux",""); pane=tm.rsplit(".",1)[-1] if "." in tm else ""
try: cur=subprocess.run(["tmux","display","-p","-t",pane,"#{session_name}"],capture_output=True,text=True,timeout=3).stdout.strip() if pane else ""
except Exception: cur=""
br=d.get("bridgeSessionId") or ""
pj=d.get("parkedJobId")
if pj and not br:   # parked on a background job: the job row holds the Remote Control bridge; its row is not listed (no tmux)
    import glob
    for q in glob.glob(os.path.join(os.path.dirname(p),"*.json")):
        try: j=json.load(open(q))
        except Exception: continue
        if j.get("pid")!=d.get("pid") and (j.get("jobId")==pj or j.get("sessionId")==pj) and j.get("bridgeSessionId"): br=j["bridgeSessionId"]; break
print("%s\t%s\t%s" % (d.get("name","?"), br, cur or tm.split(":")[0]))' "$f" 2>/dev/null
  done | sort
)
emit() {
  echo "# Remote Control session map"; echo
  echo "_Generated $(cs_date '+%Y-%m-%d %H:%M %Z') by \`salamander map\`._"; echo
  echo "| real session | claude.ai URL | tmux |"; echo "|---|---|---|"
  while IFS=$'\t' read -r name bridge tm; do
    [ -n "$name" ] || continue
    if [ -n "$bridge" ]; then url="https://claude.ai/code/$bridge"; else url="_(no bridge)_"; fi
    echo "| \`$name\` | $url | \`$tm\` |"
  done <<< "$rows"
}
emit
if [ -n "$OUT" ]; then mkdir -p "$(dirname "$OUT")"; emit > "$OUT"; echo; echo "✅ written: $OUT"; fi
