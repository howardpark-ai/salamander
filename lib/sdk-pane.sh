# lib/sdk-pane.sh — the sdk lane's pane program (Wed Oct 14th 2026; common.sh "lanes"): what resume_cmd types into a
# pane's shell in place of `claude --resume <uuid>` for a session recorded on sdk.
#
#   salamander sdk-pane <uuid> [<session>|-] [--model M] [--effort E]
#
# WHY A PROGRAM AND NOT A PREFIX. The API credit on the key (the promotional grants, and any top-up since)
# pays for Agent SDK calls on the key and refuses anything sent as Claude Code — the api lane's `claude` with the key gets
# "credit balance is too low" — so the only way a pane spends it is the real SDK (claude-agent-sdk, pinned by
# SALA_LANE_SDK_PIN), which spawns the CLI itself and marks it as its own (CLAUDE_CODE_ENTRYPOINT=sdk-py: the SDK sets it,
# sala never does; a CLI dressed up as the SDK would misreport its usage). The SDK's CLI registers in ~/.claude/sessions as
# any pane's does (pid, session id, name, status, the tmux pane it inherited, the messaging socket), loads the user settings
# when told to (hooks, so sala's busy record; plugins, so the mod) and answers the inbox socket by itself, so sala's idle
# checks, /exit and resume see a claude pane. What it lacks is a screen: contrib/sdk-pane/driver.py is the screen — it
# prints the turn's messages and keeps a ❯ box at the bottom that sala-web's input_box and sala's pane_draft read.
#
# THIS WRAPPER (bash) does the parts that belong to sala, around the driver:
#   1. renames itself: `exec -a sala-sdk bash …` so the pane's foreground command reads `sala-sdk` (tmux reads the job
#      leader's argv[0]) — never a shell's name, which the sweep (check_pane), exit_wait and resume_send treat as "a shell
#      sits here" (resume_send would type a resume line INTO the driver); check_pane takes a `sala-sdk` pane whose claude
#      runs on sdk (proc_lane) as a claude pane
#   2. the credit gate: while the shared record (lib/api_credit.py, ${XDG_STATE_HOME:-~/.local/state}/api-credit/state.json)
#      holds a refusal less than API_CREDIT_RETRY_S (6 h) old it runs the subscription-1 line in its place (exec, so `claude` is the
#      pane's program); with no refusal, or an older one, it starts the driver and the key is tried
#   3. runs the driver under `uv run --quiet --no-project --with <pin> python -I` (SALA_LANE_SDK_CMD in the tests), handing
#      it the PATHS of the key, the workspace id and the --mcp-config (the api lane's files), sala's own claude launcher as
#      the CLI (cli_path: the SDK's bundled CLI is another version, which a recycle would read as stale), the model and the
#      effort; the key's value is read by the driver and goes only into the environment of the CLI it spawns
#   4. the credit fallback: the driver exits 3 when a turn came back refused by the credit (billing_error / "credit balance") and
#      has written the shared record; a turn that works removes it. On the 3 the row is rewritten to subscription-1, one post says so in plain words, and its line is exec'd here, at once — the pane
#      never sits refused. Any other exit leaves the pane at its shell with a line saying so; sala's next revive resumes it.
# Exit: the driver's (0 left on /exit or the CLI's own end · 1 the CLI died or the SDK failed · 2 usage), or the exec'd line's.
usage() { echo "usage: salamander sdk-pane <uuid> [<session>|-] [--model <model>] [--effort <level>]" >&2; exit 2; }
RUN=0; UUID=""; SESS=""; MODEL=""; EFFORT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --run) RUN=1 ;;
        --model) MODEL="${2:-}"; shift ;;
        --effort) EFFORT="${2:-}"; shift ;;
        -h|--help) usage ;;
        -*) echo "sala-sdk: unknown option $1" >&2; usage ;;
        *) if [ -z "$UUID" ]; then UUID="$1"; elif [ -z "$SESS" ]; then SESS="$1"; else usage; fi ;;
    esac
    shift
done
[ -n "$UUID" ] || usage
case "$UUID" in *[!0-9a-fA-F-]*) echo "sala-sdk: '$UUID' is not a conversation id" >&2; exit 2 ;; esac
[ "$SESS" = - ] && SESS=""
[ -z "$MODEL" ] || model_valid "$MODEL" || { echo "sala-sdk: bad model '$MODEL'" >&2; exit 2; }
[ -z "$EFFORT" ] || effort_known "$EFFORT" || { echo "sala-sdk: bad effort '$EFFORT'" >&2; exit 2; }

# 1. the name the pane's readers see (the header)
if [ "$RUN" = 0 ]; then
    exec -a sala-sdk "${BASH:-bash}" "$SALA_BIN" sdk-pane --run "$UUID" "${SESS:--}" ${MODEL:+--model "$MODEL"} ${EFFORT:+--effort "$EFFORT"}
fi

# exec_line <why> — the session's resume line with the credit record holding a refusal (the subscription-1 line, whatever the row says; the
# subscription-1 line carries no key), run in this pane's place: `bash -c` execs a simple command, so the pane's program reads `claude`
exec_line() {
    local line; line=$(resume_cmd "$UUID" "$SESS")   # the record is closed by now: the date gate's caller found it so, and the exit-3 path below wrote it
    case "$line" in *" sdk-pane "*) echo "sala-sdk: $1 — but the resume line is still the sdk lane's; the pane stays at its shell" >&2; exit 1 ;; esac
    echo "sala-sdk: $1 — resuming on the subscription-1 line in this pane:"; echo "  $line"
    exec "${BASH:-bash}" -c "$line"
}

# 2. the credit gate (common.sh sdk_window_open; the row stays, lane_for_session gives subscription-1, resume_cmd logs the fallback)
sdk_window_open || exec_line "$(sdk_closed_why)"

# 3. the driver
[ -r "$SALA_LANE_API_KEY_FILE" ] || { echo "sala-sdk: the key file $SALA_LANE_API_KEY_FILE is missing or unreadable (SALA_LANE_API_KEY_FILE)" >&2; exit 1; }
DRIVER="$SALA_ROOT/contrib/sdk-pane/driver.py"
[ -r "$DRIVER" ] || { echo "sala-sdk: the driver is missing at $DRIVER" >&2; exit 1; }
cmd=(uv run --quiet --no-project --with "$SALA_LANE_SDK_PIN" python -I)
[ -n "$SALA_LANE_SDK_CMD" ] && read -ra cmd <<< "$SALA_LANE_SDK_CMD"
args=("$DRIVER" --resume "$UUID" --key-file "$SALA_LANE_API_KEY_FILE" --cli "$SALA_CLAUDE")
[ -n "$SESS" ] && args+=(--session "$SESS")
[ -r "$SALA_LANE_API_WORKSPACE_FILE" ] && args+=(--workspace-file "$SALA_LANE_API_WORKSPACE_FILE")
[ -n "$SALA_LANE_API_MCP_CONFIG" ] && [ -r "$SALA_LANE_API_MCP_CONFIG" ] && args+=(--mcp-config "$SALA_LANE_API_MCP_CONFIG")
[ -n "$MODEL" ] && args+=(--model "$MODEL")
[ -n "$EFFORT" ] && args+=(--effort "$EFFORT")
# the pane's shell may carry a key of its own (a by-hand api pane): the driver's files are the one source
env -u ANTHROPIC_API_KEY -u ANTHROPIC_CUSTOM_HEADERS "${cmd[@]}" "${args[@]}"; rc=$?
case "$rc" in
    0) exit 0 ;;
    3)  # 4. the credit refused a turn: subscription-1 from now on, said once, the pane resumed there at once
        echo "sala-sdk: the API credit refused this session's turn — back on the $(lane_label subscription-1) login"
        sdk_window_open && api_credit_refuse "sdk-pane ${SESS:-$UUID}" "the driver exited 3: the credit refused a turn"   # the driver wrote the record; this is for a driver that could not
        if [ -n "$SESS" ]; then
            lane_write "$SESS" subscription-1 || echo "sala-sdk: could not record the lane for '$SESS' (see above); the resume line below is subscription-1's for this launch only" >&2
            lane_log fallback "$SESS" "sdk → subscription-1 (the credit refused a turn)"
            "$SALA_BIN" alert "sala: $SESS is back on the $(lane_label subscription-1) login" \
                "The API credit refused its turn (the sdk lane), so sala recorded the $(lane_label subscription-1) login for it and resumed the conversation there; the last message may need to be sent again." \
                "To put it back on the credit: salamander lane sdk $SESS" >/dev/null 2>&1 || true
        else
            lane_log fallback - "sdk → subscription-1 (the credit refused a turn; no session name, nothing recorded)"
        fi
        [ -n "$SESS" ] || echo "sala-sdk: no session name was given, so nothing is recorded; the subscription-1 line for this launch only" >&2
        exec_line "the credit refused a turn${SESS:+ ($SESS recorded on subscription-1)}" ;;
    *)  echo "sala-sdk: the driver ended (exit $rc) — the pane is at its shell; sala's next revive resumes $UUID${SESS:+ for $SESS} on its lane" >&2; exit "$rc" ;;
esac
