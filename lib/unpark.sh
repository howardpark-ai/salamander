# lib/unpark.sh — bring a parked conversation back into its pane.
#
#   salamander unpark <tmux-session> [--dry-run]
#
# Claude Code 2.1.28x: the "← for agents" key in a pane PARKS its conversation — a transient
# `claude daemon run` starts under the pane's process and forks the conversation into a background
# pty session (`--session-id <new> --fork-session --resume <old>`); the fork's registry row takes the
# Remote Control bridge, the pane's row gets `parkedJobId = <new>` and a null bridge; Esc returns
# the view, not the state. Everything typed from claude.ai afterwards lands in the FORK's transcript,
# so the pane's own conversation goes stale and a plain recycle would resume the wrong one.
# Exercised once, on 2.1.282. Steps, each verified:
#   1. the fork must be idle (registry) — its transcript is flushed per turn, so ending it loses nothing
#   2. SIGTERM the fork process (a bg session ignores /exit) and its bg-pty-host; wait for the registry row to go
#   3. in the pane: Esc (the CLI notices the job ended, stays in its list view), then Ctrl-C twice — the
#      list view's own quit — until the pane is a shell. The stale conversation's transcript stays on disk.
#   4. `claude --resume <fork uuid> --effort <from transcript>` in the pane; the bridge reattaches from the
#      fork transcript's remote_session_change record; the name comes back "derived", so /rename it
#   5. the pane map row moved to the fork (an honored add); verify exactly one registry row holds the bridge
#   The session registry's row (phase 2) gets the fork as a `resume` conversation first (sessions_record_soft), by the
#   same record call the SessionStart hook uses; a repeat is a no-op, a failure one line in sessions.log.

name="${1:-}"; DRY=0
case "$name" in ''|-*) die "usage: salamander unpark <tmux-session> [--dry-run]";; esac
shift; while [ $# -gt 0 ]; do case "$1" in --dry-run) DRY=1 ;; *) die "unknown option: $1" ;; esac; shift; done
[ "$DRY" = 1 ] || ledger_frozen_die unpark   # a recycle or reboot holds the pane map
tmux has-session -t "=$name" 2>/dev/null || die "no tmux session '$name'"
pane=$(tmux list-panes -t "$(tmux_win_t "$name")" -F '#{pane_id}' | head -1)
panepid=$(tmux display -p -t "$pane" '#{pane_pid}')
cpid=$(claude_pid_under "$panepid") || die "'$name': no claude process in the pane"
old=$(registry_field "$cpid" sessionId); fork=$(registry_field "$cpid" parkedJobId); [ "$fork" = null ] && fork=""
label=$(registry_field "$cpid" name)
[ -n "$fork" ] || die "'$name' is not parked (registry has no parkedJobId for pid $cpid)"
[ -n "$(transcript_for_uuid "$fork")" ] || die "'$name': parkedJobId $fork has no transcript on disk — nothing to resume; leave the pane as it is"
# the fork's process, if still running: the registry row whose sessionId is the fork
fpid=""; for f in "$SALA_REG_DIR"/*.json; do p=${f##*/}; p=${p%.json}; case "$p" in ''|*[!0-9]*) continue;; esac; proc_alive "$p" || continue
    [ "$(registry_field "$p" sessionId)" = "$fork" ] && { fpid="$p"; break; }; done
bridge=$(bridge_for_uuid "$fork")
echo "'$name' (${label:-?}): pane conversation $old is parked; live conversation = fork $fork${fpid:+ (running as pid $fpid)}${bridge:+, bridge $bridge}"
if [ -n "$fpid" ]; then
    why=$(is_idle_reason "$fpid"); [ -z "$why" ] || die "the fork is not idle ($why) — ${SALA_OWNER_NAME} may be mid-turn on claude.ai; wait and rerun"
fi
d=$(pane_draft "$pane" "$cpid"); [ -z "$d" ] || die "unsubmitted text in the pane's composer (\"$d\") — clear it first"
if [ "$DRY" = 1 ]; then echo "[dry-run] would end fork pid ${fpid:-none}, quit the pane's stale claude (pid $cpid), resume $fork in $pane, rename to '${label:-$name}'"; exit 0; fi

if [ -n "$fpid" ]; then
    fppid=$(proc_ppid "$fpid")
    echo "ending the fork process $fpid (idle) ..."; kill -TERM "$fpid" 2>/dev/null
    for ((i=0; i<20; i++)); do proc_alive "$fpid" || break; sleep 1; done
    proc_alive "$fpid" && die "fork pid $fpid did not exit within 20 s — not forcing; check it by hand"
    proc_args "$fppid" 2>/dev/null | grep -q -- '--bg-pty-host' && { kill -TERM "$fppid" 2>/dev/null; sleep 1; }
fi
unmode "$pane"; tmux send-keys -t "$pane" Escape; sleep 3          # the CLI notices the ended job, stays in its list view
echo "quitting the pane's stale claude (pid $cpid) ..."
for ((i=0; i<3; i++)); do
    tmux send-keys -t "$pane" C-c; sleep 0.7; tmux send-keys -t "$pane" C-c
    wait_for "$pane" shell 10 && break
done
wait_for "$pane" shell 5 || die "the pane did not return to a shell — screen: $(tmux capture-pane -p -t "$pane" | grep -v '^ *$' | tail -2 | tr '\n' ' ')"
cmd=$(resume_cmd "$fork" "$name"); echo "resuming: $cmd"   # on the session's lane (common.sh, lanes)
why=$(resume_send "$pane" "$fork" "$cmd") || die "$why"
resume_wait "$pane" "$fork" 30; rc=$?   # live, not merely started
[ "$rc" = 2 ] && die "the resume started and died within 30 s — the pane is back at a shell, the error above its prompt; run by hand: $cmd"
[ "$rc" = 0 ] || die "resume did not start within 30 s — the pane is at a shell; run by hand: $cmd"
npid=""; for ((i=0; i<40; i++)); do npid=$(claude_pid_under "$(tmux display -p -t "$pane" '#{pane_pid}')"); b=$(registry_field "$npid" bridgeSessionId 2>/dev/null); [ -n "$b" ] && [ "$b" != null ] && break; sleep 1; done
if [ -n "${label:-}" ] && [ "$(registry_field "$npid" name)" != "$label" ]; then
    sleep 2; pane_rename "$pane" "$npid" "$label" && sleep 3   # the mod first, else /rename typed (lib/common.sh)
fi
# the pane's row now names the fork: an honored add (the map is a ledger — common.sh), not a map rebuild
ucwd=$(registry_field "$npid" cwd); [ -n "$ucwd" ] && [ "$ucwd" != null ] || ucwd=$(tmux display -p -t "$pane" '#{pane_current_path}')
sessions_record_soft "$name" "$fork" resume   # the session registry (phase 2): the fork joins the row as a resume; ledger_write's add below then finds it listed. Never fails the unpark
ledger_write add "$name" "$fork" "$(registry_field "$npid" name)" "$ucwd" || echo "⚠ the pane map still names $old for '$name' (see above) — sala adopt $name fixes it"
holders=$(grep -l "\"bridgeSessionId\" *: *\"${b:-none}\"" "$SALA_REG_DIR"/*.json 2>/dev/null | wc -l)
echo "✅ '$name' is on $fork (pid $npid, name '$(registry_field "$npid" name)'), bridge ${b:-NOT YET — type /remote-control in the pane}; holders of the bridge: $holders"
[ "$holders" = 1 ] || echo "⚠ expected exactly one registry row on that bridge"
echo "   the stale conversation $old keeps its transcript (claude --resume $old brings it back by hand)"
