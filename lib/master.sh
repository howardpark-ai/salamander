# lib/master.sh — who is the master session, and is it live.
#
#   salamander master           name, tmux/claude state, conversation, bridge, idle — one line each
#   salamander master --name    just the name (empty + exit 1 when SALA_MASTER is unset)
#   salamander master --json    {"name","live","tmux","pid","session","bridge","idle_reason"}
#   salamander master --set NAME designate an existing tmux session as the master (writes SALA_MASTER into the config)
#   salamander master --unset   no master from now on: SALA_MASTER commented out in the config, the watchdog's records of it
#                               dropped (nothing heals, recreates or bridges it; the post-boot report goes to Slack)
#
# The master is the one session `salamander watch` keeps alive (SALA_MASTER in the config). It was the operator for cues
# like "recycle claude": the session that HEARS such a cue resolved the master here and handed the cue to it, never ran
# it itself — a recycle relaunches every pane on the box, the hearing one included, and only one driver may hold it.
# Since the operation queue (lib/op.sh) a master is OPTIONAL: `sala op <verb> … --from NAME --words "…"`
# queues the operation and sala's watch runs it with no model; `sala op retire <the master>` unsets SALA_MASTER first
# (this --unset) and then retires it, one operation. Off-box callers (cloud, Cowork, other machines) cannot read the
# config; `salamander heartbeat` publishes the same name ("" when unset) and the master's conversation id in
# machine.json (stackshot no longer reads that file; nothing reads these two keys today).
# Exit status: 0 master live (claude running in its pane) · 1 unset · 2 set but not live.

mode="${1:-}"
case "$mode" in ''|--name|--json|--set|--unset) ;; *) die "usage: salamander master [--name|--json|--set NAME|--unset]" ;; esac
HOWTO="designate one:  salamander master --set <existing tmux session>     or spawn one:  salamander spawn <name> --master"
QUEUE="fleet operations go through the queue: sala op <verb> … --from <you> --words \"<${SALA_OWNER_NAME}'s words>\" (sala op --help lists the verbs)"
st="$SALA_LOG_DIR/salamander-watch.state"
st_drop() {  # <key>… — those lines out of the watch state (the master's records), the file rewritten once
    local k pat=""; for k in "$@"; do pat="$pat${pat:+|}^$k="; done
    [ -s "$st" ] || return 0
    grep -vE "$pat" "$st" > "$st.tmp.$$"; mv -f "$st.tmp.$$" "$st"
}
if [ "$mode" = --set ]; then
    # designate an existing session as the master: write SALA_MASTER into the config (the owner's user config —
    # this is the one line sala writes there), then point at the watchdog timer if it is not running yet
    new="${2:-}"; [ -n "$new" ] || die "usage: salamander master --set <tmux session>   ($HOWTO)"
    tmux has-session -t "=$new" 2>/dev/null || die "no tmux session '$new' — spawn it first: salamander spawn $new --master"
    claude_pid_under "$(tmux display -p -t "$(tmux list-panes -t "$(tmux_win_t "$new")" -F '#{pane_id}' | head -1)" '#{pane_pid}')" >/dev/null 2>&1 || echo "⚠ '$new' has no claude process right now — the watchdog will revive it from the sidecar, or resume one there yourself"
    mkdir -p "$(dirname "$SALA_CONFIG")"
    [ -e "$SALA_CONFIG" ] || { cp "$SALA_ROOT/config.example" "$SALA_CONFIG" 2>/dev/null || >> "$SALA_CONFIG"; }
    if grep -q '^SALA_MASTER=' "$SALA_CONFIG"; then sed -i.bak "s|^SALA_MASTER=.*|SALA_MASTER=$new|" "$SALA_CONFIG" && rm -f "$SALA_CONFIG.bak"
    else printf '\nSALA_MASTER=%s   # the master session: recycle driver, kept alive by `salamander watch` (set by: salamander master --set)\n' "$new" >> "$SALA_CONFIG"; fi
    # its directory, for watch to recreate the session there if it ever disappears (watch keeps it current while it lives);
    # a --unset's record goes (a master again is not a lost config)
    npane=$(tmux list-panes -t "$(tmux_win_t "$new")" -F '#{pane_id}' | head -1)
    ncpid=$(claude_pid_under "$(tmux display -p -t "$npane" '#{pane_pid}')" 2>/dev/null)
    ndir=$( { [ -n "$ncpid" ] && readlink "/proc/$ncpid/cwd"; } 2>/dev/null || tmux display -p -t "$npane" '#{pane_current_path}')
    mkdir -p "$SALA_LOG_DIR"; st_drop master_unset
    if [ -n "$ndir" ]; then _kv_set "$st" "cwd.$new" "$ndir"; fi
    echo "✅ master = '$new' (SALA_MASTER in $SALA_CONFIG${SALA_MASTER:+, was '$SALA_MASTER'})" directory: ${ndir:-unknown}
    if command -v systemctl >/dev/null 2>&1 && ! systemctl --user is-active sala-watch.timer >/dev/null 2>&1; then
        echo "   watchdog not running — enable it: cp $SALA_ROOT/systemd/sala-watch.{service,timer} ~/.config/systemd/user/ && systemctl --user daemon-reload && systemctl --user enable --now sala-watch.timer"
    fi
    exit 0
fi
if [ "$mode" = --unset ]; then
    # NO MASTER (Thu Oct 15th 2026): the one config line sala writes, commented out rather than removed, so the
    # file still says what the knob is; the file is checked to parse and to name no master afterwards. The watchdog's
    # records of the master (its name, conversation, bridge, directory) go, so `watch` and `master` read "unset", never
    # "config lost"; the when and the name stay as master_unset. The last-good copy (common.sh) is refreshed only while a
    # master is set, so it is refreshed here once: a later "restore from last-good" must not bring the master back.
    [ $# -le 1 ] || die "usage: salamander master --unset   (takes nothing else)"
    old="${SALA_MASTER:-}"
    if [ -z "$old" ] && ! { [ -r "$SALA_CONFIG" ] && grep -q '^SALA_MASTER=' "$SALA_CONFIG"; }; then
        echo "no master to unset: SALA_MASTER is not set in $SALA_CONFIG$(u=$(awk -F= '$1=="master_unset"{print $2}' "$st" 2>/dev/null); [ -n "$u" ] && echo " (unset $(local_human "${u##* }"), was '${u%% *}')")"; exit 0
    fi
    [ -r "$SALA_CONFIG" ] || die "SALA_MASTER=$old comes from the environment, not from a readable config ($SALA_CONFIG): nothing to unset here"
    [ -w "$SALA_CONFIG" ] && [ -w "$(dirname "$SALA_CONFIG")" ] || die "$SALA_CONFIG (or its directory) is not writable: SALA_MASTER=$old stays"
    when=$(date +%s); edited="SALA_MASTER commented out in $SALA_CONFIG"
    if grep -q '^SALA_MASTER=' "$SALA_CONFIG"; then
        sed -i.bak "s|^SALA_MASTER=.*|#SALA_MASTER=                     # unset $(local_human "$when") by \`salamander master --unset\`${old:+ (was $old)}: the operation queue (sala op) runs fleet operations; a master is optional (salamander master --set)|" "$SALA_CONFIG" || die "could not edit $SALA_CONFIG — SALA_MASTER=$old stays (the copy: $SALA_CONFIG.bak)"
        rm -f "$SALA_CONFIG.bak"
        bash -n "$SALA_CONFIG" 2>/dev/null || die "$SALA_CONFIG does not parse after the edit — check it by hand (diff against $SALA_CONFIG_LASTGOOD)"
    else edited="no SALA_MASTER line in $SALA_CONFIG (the value came from the environment of this call)"; fi
    left=$( SALA_MASTER=""; . "$SALA_CONFIG" >/dev/null 2>&1; printf '%s' "${SALA_MASTER:-}" )
    [ -z "$left" ] || die "$SALA_CONFIG still names a master after the edit ($left) — check it by hand"
    mkdir -p "$SALA_LOG_DIR"; touch "$st"
    st_drop master uuid bridge lane_norc ${old:+"cwd\\.$old"}
    { grep -v '^master_unset=' "$st"; echo "master_unset=${old:-?} $when"; } > "$st.tmp.$$" && mv -f "$st.tmp.$$" "$st"
    cp -f "$SALA_CONFIG" "$SALA_CONFIG_LASTGOOD" 2>/dev/null || true
    echo "✅ master unset${old:+ (was '$old')}: $edited; the watchdog's records of it dropped ($st); last-good copy refreshed"
    echo "   from now on nothing heals, recreates or bridges a master session, the post-boot report goes to Slack, and \`sala cue\` points to the queue: $QUEUE"
    echo "   a master again: $HOWTO"
    exit 0
fi
name="${SALA_MASTER:-}"
if [ -z "$name" ]; then
    case "$mode" in --name) exit 1 ;; --json) echo '{"name": "", "live": false}'; exit 1 ;; esac
    echo "no master: SALA_MASTER is not set in $SALA_CONFIG$([ -r "$SALA_CONFIG" ] || echo ' (the file is missing or unreadable)')"
    known=$(awk -F= '$1=="master"{print $2}' "$st" 2>/dev/null); kuuid=$(awk -F= '$1=="uuid"{print $2}' "$st" 2>/dev/null)
    unset_rec=$(awk -F= '$1=="master_unset"{print $2}' "$st" 2>/dev/null)
    if [ -n "$unset_rec" ]; then
        echo "unset on purpose, $(local_human "${unset_rec##* }") (was '${unset_rec%% *}'; salamander master --unset): $QUEUE"
        echo "the watchdog keeps no master alive (it still revives any pane whose claude died); the post-boot report goes to Slack. A master again: $HOWTO"
    elif [ -n "$known$kuuid" ]; then
        echo "but this box HAD one: ${known:-?}${kuuid:+ (conversation $kuuid)} per the watchdog state — the config was lost or truncated."
        [ -r "$SALA_CONFIG_LASTGOOD" ] && echo "restore: diff $SALA_CONFIG $SALA_CONFIG_LASTGOOD  (last-good copy, $(date -r "$SALA_CONFIG_LASTGOOD" '+%Y-%m-%d %H:%M'))  — or re-apply your config"
        echo "until then: no recycle cue can be delivered; the watchdog heals nothing; the master pane itself may still be running (check: tmux ls). Meant to have none? salamander master --unset records that"
    else
        echo "never set on this box — a master is optional: $QUEUE. $HOWTO"
    fi
    exit 1
fi
[ "$mode" = --name ] && { echo "$name"; exit 0; }
live=false; tmux_ok=false; pid=""; sid=""; bridge=""; why=""
if tmux has-session -t "=$name" 2>/dev/null; then
    tmux_ok=true; pane=$(tmux list-panes -t "$(tmux_win_t "$name")" -F '#{pane_id}' | head -1)
    pid=$(claude_pid_under "$(tmux display -p -t "$pane" '#{pane_pid}')" || true)
    if [ -n "$pid" ]; then
        live=true; sid=$(registry_field "$pid" sessionId); bridge=$(registry_field "$pid" bridgeSessionId); [ "$bridge" = null ] && bridge=""
        [ -z "$bridge" ] && [ -n "$sid" ] && bridge=$(bridge_for_uuid "$sid")
        why=$(is_idle_reason "$pid")
    fi
fi
if [ "$mode" = --json ]; then
    python3 -c 'import json,sys; print(json.dumps({"name":sys.argv[1],"live":sys.argv[2]=="true","tmux":sys.argv[3]=="true","pid":sys.argv[4],"session":sys.argv[5],"bridge":sys.argv[6],"idle_reason":sys.argv[7]}))' "$name" "$live" "$tmux_ok" "$pid" "$sid" "$bridge" "$why"
else
    echo "master      : $name"
    if [ "$live" = true ]; then
        echo "state       : live (tmux session '$name', claude pid $pid)"
        echo "conversation: ${sid:-?}"
        echo "bridge      : ${bridge:+https://claude.ai/code/}${bridge:-none}"
        echo "idle        : ${why:+no — $why}${why:-yes}"
    elif [ "$tmux_ok" = true ]; then echo "state       : NOT LIVE — tmux session exists but no claude process (salamander watch heals it within 2 min, or: salamander revive --only $name)"
    else echo "state       : NOT LIVE — no tmux session '$name' (salamander watch heals it within 2 min)"; fi
fi
[ "$live" = true ] && exit 0 || exit 2
