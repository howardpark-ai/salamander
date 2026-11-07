# lib/update.sh — update the Claude Code CLI here, and optionally on every other machine you run it on.
#
#   salamander update                 this machine: `claude update`, then relaunch every pane
#                                     (= `salamander recycle --update --force`)
#   salamander update HOST…           `claude update` on just those hosts (names from SALA_FLEET_HOSTS);
#                                     this machine only if named — "update claude on box1" = `salamander update box1`
#   salamander update --fleet         every SALA_FLEET_HOSTS host, then this machine
#   salamander update … --check       report installed versions only; change nothing anywhere
#   salamander update … --no-recycle  this machine: `claude update` only, no relaunch (no master guard, no recycle lock);
#                                     the panes keep their version until a recycle — watch's at-once auto-update
#
# Remote hosts are ssh aliases (key auth, BatchMode) with a POSIX shell (Linux or macOS; sala is off Windows since
# Thu Oct 15th 2026). A host that does not answer within SALA_FLEET_TIMEOUT seconds is "offline, skipped" —
# laptops sleep; that is not a failure. Remotes are CLI-only: no tmux
# panes to relaunch there, so a session already running on a remote keeps its old binary until it
# is restarted by hand — the report says so instead of trying. Only `claude update` (the native
# installer) is ever run remotely: package managers (brew, apt) are not touched.
# Order: remotes first, then the post-update hook (SALA_POST_UPDATE_CMD, e.g. bump a dashboard), then this machine's
# recycle LAST — it relaunches the pane you ran this from, once idle.

FLEET=0; CHECK=0; NOTMASTER=""; HOSTS=()
AUTO=0; RELEASE=0; NORECYCLE=0
while [ $# -gt 0 ]; do case "$1" in --fleet) FLEET=1 ;; --check) CHECK=1 ;; --auto) AUTO=1 ;; --release) RELEASE=1 ;; --no-recycle) NORECYCLE=1 ;; --not-master) NOTMASTER=--not-master ;; -*) die "usage: salamander update [HOST…|--fleet] [--check] [--auto [--release]] [--no-recycle] [--not-master]" ;; *) HOSTS+=("$1") ;; esac; shift; done
: "${SALA_FLEET_HOSTS:=}"
ME=$(hostname); LOCAL=1; REMOTES=()
if [ "$FLEET" = 1 ]; then
    [ ${#HOSTS[@]} -eq 0 ] || die "give either --fleet or host names, not both"
    [ -n "$SALA_FLEET_HOSTS" ] || die "SALA_FLEET_HOSTS is empty in $SALA_CONFIG — nothing to update beyond this machine"
    REMOTES=($(fleet_hosts))
elif [ ${#HOSTS[@]} -gt 0 ]; then
    LOCAL=0
    for h in "${HOSTS[@]}"; do
        if [ "$h" = "$ME" ]; then LOCAL=1
        elif printf '%s\n' $SALA_FLEET_HOSTS | grep -qx -- "$h"; then REMOTES+=("$h")
        else die "unknown host '$h' — this machine is $ME; SALA_FLEET_HOSTS = ${SALA_FLEET_HOSTS:-<empty>}"; fi
    done
fi
# the local leg is a recycle of this box: one driver only (see master_guard) — checked before any remote is touched.
# --no-recycle relaunches nothing, so it needs neither the guard nor the lock below
[ "$LOCAL" = 1 ] && [ "$CHECK" = 0 ] && [ "$NORECYCLE" = 0 ] && master_guard update $NOTMASTER
# … and the recycle lock (common.sh), held from here through the detached driver the recycle at the end starts (fd 9 crosses
# the exec). --auto (watch's unit, launched after watch found the lock free) waits for it rather than lose its one try per version
if [ "$LOCAL" = 1 ] && [ "$CHECK" = 0 ] && [ "$NORECYCLE" = 0 ]; then
    recycle_lock "$([ "$AUTO" = 1 ] && echo "${SALA_LOCK_WHO:-auto-update}" || lock_who)" "$([ "$AUTO" = 1 ] && echo 600 || echo 0)" || recycle_refuse
    export SALA_RECYCLE_LOCKED=1
fi
ULOG="$SALA_LOG_DIR/salamander-update.log"; mkdir -p "$SALA_LOG_DIR"
ulog() { echo "[$(date -Is)] $*" >> "$ULOG"; }
SSH=("${SALA_SSH[@]}")


# open_sessions <fleet name> → "N|name, name" — the Remote-Control sessions the heartbeat last saw on that box (live store,
# swept every 5 min; says how many keep the old version instead of a blanket warning); empty when unknown
open_sessions() {
    local fn="${SALA_FLEET_NAMES/#\~/$HOME}" sd="${SALA_HEARTBEAT_STATE_DIR/#\~/$HOME}" L
    L=$(awk -F'\t' -v h="$1" '!/^#/ && $2==h {print $3; exit}' "$fn" 2>/dev/null)
    [ -n "$L" ] && [ -r "$sd/$L/sessions.json" ] || return 0
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); n=sorted(v.get("name") or "unnamed" for v in d.values()); print("%d|%s" % (len(n), ", ".join(n)))' "$sd/$L/sessions.json" 2>/dev/null
}
name_lines() {  # "a, b, c" → indented "◦ a, b" lines, packed so none runs past ~40 characters (Slack on a phone)
    printf '%s' "$1" | python3 -c '
import sys
out, cur = [], ""
for n in (x.strip() for x in sys.stdin.read().split(",")):
    if not n: continue
    if cur and len(cur) + 2 + len(n) > 30: out.append(cur); cur = n
    else: cur = cur + ", " + n if cur else n
if cur: out.append(cur)
print("".join("\n        ◦ " + l for l in out), end="")'
}
# auto_untry <host>: give back a spent try (Tue Oct 20th 2026). watch's auto_update records `auto_update_tried_<host>`
# = <release> BEFORE it launches this unit, on the heartbeat's word that the box is awake; a box whose link flaps can be awake
# there and silent to the probe below a minute later, and the spent try then kept it from ever being tried again for that
# release (a box that came back online a few hours later). A box skipped as offline was not tried, so --auto takes its marker out
# of the watch state, and watch's next auto_update run (every 10 min, once the heartbeat sees the box awake) launches it again.
# A real attempt, failed or not, keeps its marker: one try per host per release. (awk, so a host name is never a regex.)
auto_untry() {
    local st="$SALA_LOG_DIR/salamander-watch.state"
    [ -s "$st" ] && awk -F= -v k="auto_update_tried_$1" '$1==k {f=1} END {exit !f}' "$st" || return 0
    awk -F= -v k="auto_update_tried_$1" '$1!=k' "$st" > "$st.tmp.$$" && mv -f "$st.tmp.$$" "$st"
    ulog "$1: skipped as offline — its try for this release is given back; watch tries it again once the heartbeat sees it awake"
}
REPORT=(); local_ver=$(claude_ver)
if [ ${#REMOTES[@]} -gt 0 ]; then
    for h in "${REMOTES[@]}"; do
        IFS='|' read -r kind before after err <<< "$(remote_update "$h" "$([ "$CHECK" = 1 ] && echo check || echo update)")"
        if [ "$kind" = offline ]; then line="$h: offline, skipped"; [ "$AUTO" = 1 ] && [ "$CHECK" = 0 ] && auto_untry "$h"
        elif [ -n "$err" ]; then line="$h: FAILED — $err${before:+ (still $before)}"
        elif [ "$CHECK" = 1 ]; then line="$h: $before"
        elif [ "$before" = "$after" ]; then line="$h: already current ($after)"
        else line="$h: updated $before → $after — sessions already running there keep $before until restarted by hand"; fi
        REPORT+=("$line"); ulog "$line"; echo "  $line"
    done
fi

if [ "$CHECK" = 1 ]; then
    if [ "$LOCAL" = 1 ]; then
        panes=$("$SALA_BIN" spawn --list 2>/dev/null | awk 'NR>1 && $2 ~ /^[0-9]/ {print $2}' | sort | uniq -c | awk '{printf "%s×%s ", $1, $2}')
        echo "  $ME: launcher $local_ver; panes ${panes:-none}"
    fi
    exit 0
fi

# this box first, so the notice reports what really happened: its CLI update, then a recycle only
# when some pane still runs an older version than the installed CLI — whether or not this update moved it — and then
# only those panes are relaunched (a recycle without --force); none stale = "no recycle". An explicit "recycle claude"
# cue still forces every pane. --no-recycle (watch's at-once update): the CLI only; the stale panes are counted for the
# post, and watch relaunches them at its next run, each busy one once idle (auto_relaunch).
LCHANGED=0; STALE=0
if [ "$LOCAL" = 1 ]; then
    lb=$(claude_ver)
    if lout=$(cli_update); then   # 9>&-: a child the updater leaves behind must not hold the recycle lock
        la=$(claude_ver)
        if [ "$lb" != "$la" ]; then line="$ME: updated $lb → $la"; LCHANGED=1; else line="$ME: already current ($la)"; fi
    else line="$ME: FAILED — $(printf '%s' "$lout" | tail -1 | cut -c1-100) (still $lb)"; fi
    now_v=$(claude_ver)
    STALE=$(stale_panes "$now_v" | wc -l | tr -d ' ')
    REPORT+=("$line"); ulog "$line (stale panes: $STALE)"; echo "  $line; panes on an older version: $STALE"
fi
[ ${#REPORT[@]} -gt 0 ] && post_update_hook "$([ "$FLEET" = 1 ] && echo fleet || echo hosts): $(printf '%s; ' "${REPORT[@]}")" $(printf '%s\n' "${REPORT[@]}" | grep -v 'offline, skipped' | cut -d: -f1)
# --release (the first automatic run for a new version): the boxes this run did not touch are reported too — current or asleep,
# from the heartbeat store; and nothing is posted unless a box updated or failed
if [ "$RELEASE" = 1 ] && [ ${#REPORT[@]} -gt 0 ]; then
    printf '%s\n' "${REPORT[@]}" | grep -qE ': (updated|FAILED)' || { ulog "release run: nothing updated, no notice"; exit 0; }
    target=$(printf '%s\n' "${REPORT[@]}" | sed -n 's/.*updated [^ ]* → \([^ ]*\).*/\1/p' | head -1)
    sd="${SALA_HEARTBEAT_STATE_DIR/#\~/$HOME}"; fn="${SALA_FLEET_NAMES/#\~/$HOME}"
    for h in $SALA_FLEET_HOSTS; do
        printf '%s\n' "${HOSTS[@]}" | grep -qx -- "$h" && continue
        IFS='|' read -r ok ver <<< "$(H="$h" SD="$sd" FN="$fn" python3 -c '
import json, os
h, sd = os.environ["H"], os.environ["SD"]
L = next((l.split("\t")[2].strip() for l in open(os.environ["FN"]) if not l.startswith("#") and len(l.split("\t")) > 2 and l.split("\t")[1] == h), "")
try: fs = json.load(open(os.path.join(sd, "a", "machine.json"))).get("fleet_ssh", {}).get(h, {})
except Exception: fs = {}
try: v = json.load(open(os.path.join(sd, L, "machine.json"))).get("claude", "")
except Exception: v = ""
print("%s|%s" % ("1" if fs.get("ok") else "0", v))' 2>/dev/null)"
        if [ "$ok" != 1 ]; then REPORT+=("$h: offline, skipped")
        elif [ -n "$target" ] && [ "$ver" = "$target" ]; then REPORT+=("$h: already current ($ver)"); fi
    done
    if [ "$LOCAL" = 0 ] && [ -n "$target" ]; then
        [ "$local_ver" = "$target" ] && AFTER_LINE="$ME current" || AFTER_LINE="$ME still on $local_ver"   # its update runs at once, in its own run
    fi
fi
# a retry run (--auto, no --release) says nothing of a box that is still asleep or flapping: watch tries it again at its next
# run (auto_untry), so the line would be posted every 10 minutes. The release run's notice names it ("update when awake").
if [ "$AUTO" = 1 ] && [ "$RELEASE" = 0 ] && [ ${#REPORT[@]} -gt 0 ]; then
    kept=(); for line in "${REPORT[@]}"; do [ "${line#*: }" = "offline, skipped" ] || kept+=("$line"); done
    REPORT=(${kept[@]+"${kept[@]}"})
fi
if [ ${#REPORT[@]} -gt 0 ]; then   # one notice in the shared shape: failures first, hosts with the same outcome grouped
    fails=(); declare -A upd=(); cur=(); off=(); vers=(); nupd=0
    for line in "${REPORT[@]}"; do
        h="${line%%:*}"; rest="${line#*: }"
        case "$rest" in
            "offline, skipped") off+=("$h") ;;
            FAILED*) e="${rest#FAILED — }"; fails+=("$h update failed:"$'\n'"        ◦ ${e:0:28}$( [ ${#e} -gt 28 ] && echo …)") ;;
            "already current"*) cur+=("$h") ;;
            updated*) v="${rest#updated }"; v="${v%% — *}"; upd[$v]="${upd[$v]:+${upd[$v]}, }$h"; vers+=("$v"); nupd=$((nupd+1)) ;;
        esac
    done
    nv=$(printf '%s\n' ${vers[@]+"${vers[@]}"} | sort -u | grep -c .)
    if [ ${#fails[@]} -gt 0 ]; then head="🚨 *CLI update failed on ${#fails[@]} box$([ ${#fails[@]} -gt 1 ] && echo es)*"
    elif [ "$nv" = 1 ]; then for v in "${!upd[@]}"; do head="✅ *CLI update* · $v"; done
    elif [ "$nupd" -gt 0 ]; then head="✅ *CLI update*"
    else head="✅ *CLI update* · nothing to update"; fi
    [ "$AUTO" = 1 ] && head="$head · automatic"
    bullets=(${fails[@]+"${fails[@]}"})
    # this box's relaunch, in the bullet: at once, or (--no-recycle) left to watch's relaunch / the next recycle
    relaunch_words() { [ "$STALE" -gt 0 ] || { echo "$1"; return; }
        if [ "$NORECYCLE" = 0 ]; then echo "; relaunching $STALE pane$( [ "$STALE" -gt 1 ] && echo s)"
        elif [ "$AUTO" = 1 ]; then echo "; relaunching $STALE pane$( [ "$STALE" -gt 1 ] && echo s), each once it is idle"
        else echo "; $STALE pane$( [ "$STALE" -gt 1 ] && echo s) keep the old CLI until a recycle"; fi; }
    for v in "${!upd[@]}"; do
        win=$(echo "${upd[$v]}" | tr ',' '\n' | sed 's/^ //' | grep -vx "$ME" | paste -sd, - | sed 's/,/, /g')
        for w in $(echo "$win" | tr -d ' ' | tr ',' ' '); do   # phone width: a short line per box, names below, three a line
            IFS='|' read -r n names <<< "$(open_sessions "$w")"
            ver=$( [ "$nv" -gt 1 ] && echo " ($v)")
            if [ -z "$n" ]; then bullets+=("$w updated$ver; open sessions keep ${v%% → *}")
            elif [ "$n" = 0 ]; then bullets+=("$w updated$ver, nothing to restart")
            else bullets+=("$w updated$ver; restart $n by hand:$(name_lines "$names")"); fi
        done
        echo "${upd[$v]}" | tr ',' '\n' | sed 's/^ //' | grep -qx "$ME" && bullets+=("$ME updated$( [ "$nv" -gt 1 ] && echo " ($v)")$(relaunch_words ", all panes current")")
    done
    for h in ${cur[@]+"${cur[@]}"}; do [ "$h" = "$ME" ] && bullets+=("$ME current$(relaunch_words ", no recycle")"); done
    oc=$(printf '%s\n' ${cur[@]+"${cur[@]}"} | grep -vx "$ME" | paste -sd, - | sed 's/,/, /g'); [ -n "$oc" ] && bullets+=("$oc current")
    [ ${#off[@]} -gt 0 ] && bullets+=("$(printf '%s\n' "${off[@]}" | paste -sd, - | sed 's/,/, /g') offline$( [ "$AUTO" = 1 ] && echo ", update when awake" || echo ", skipped")")
    [ -n "${AFTER_LINE:-}" ] && bullets+=("$AFTER_LINE")
    [ ${#fails[@]} -gt 0 ] && bullets+=("Details: ${ULOG/#$HOME/\~}")
    sala_post "$head" "${bullets[@]}"
fi
[ "$LOCAL" = 1 ] && [ "$STALE" -gt 0 ] && [ "$NORECYCLE" = 0 ] || exit 0
echo "  $ME: relaunching the $STALE pane(s) on an older version (this one last, if it is one of them) ..."
SALA_RELAUNCH_KIND=update exec "$SALA_BIN" recycle $NOTMASTER   # the CLI is already updated above: only the stale panes, the invoker too only if stale; KIND: what a waiting pane is told
