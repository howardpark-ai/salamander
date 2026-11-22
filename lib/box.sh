# lib/box.sh — `sala box SESSION [--json]`: what is in a session's pane input box, as one of three states (docs/subcommands.md).
# Sourced by bin/salamander. Read-only: it reads the screen (`tmux capture-pane -pe`, which keeps the dim attribute) and the mod's
# draft the way pane_draft does, and sends no key and writes no log line.
#   empty       nothing in the box
#   suggestion  only dim text: Claude Code's own suggested next prompt, which nobody typed; it counts as empty (typing replaces it)
#   typed       non-dim text: someone's unsent words (pane_draft's reading, the mod's text first)
# Exit: 0 read, 2 usage or no live session / no pane, 3 no claude in the pane.

box_usage() {
    cat <<'USAGE'
usage: sala box SESSION [--json]

  Prints what is in the input box of SESSION's pane, as one of three states on the first line:
    empty       nothing is in the box.
    suggestion  only dim text: Claude Code's own suggested next prompt, which nobody typed. It counts as empty (typing over it
                replaces it). The text follows on the next line, labelled as Claude Code's own suggestion, not typed by anyone.
    typed       non-dim text: unsent words someone typed (or typed on claude.ai and not sent). The text follows on the next line.
  --json    one object instead: {"session":"…","state":"empty|suggestion|typed","text":"…"} (text is "" when empty).

  A session reads a pane's box with this command, never raw `tmux capture-pane`: a capture without the attributes shows the dim
  suggestion exactly like typed text, and a session that takes it for someone's words refuses, quotes or relays text nobody wrote.
  Read-only (no key is sent, nothing is logged); it works on the caller's own pane too.
  Exit 0 read · 2 usage, no live session of that name, or no tmux pane · 3 no claude in the pane.
USAGE
}

box_main() {
    local json=0 name="" pane cpid typed sugg state text
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help) box_usage; return 0 ;;
            --json) json=1 ;;
            --) shift; [ $# -le 1 ] || { echo "sala box: one session name only" >&2; return 2; }; name=${1:-}; break ;;
            -*) echo "sala box: unknown option $1 (see sala box --help)" >&2; return 2 ;;
            *) [ -z "$name" ] || { echo "sala box: one session name only" >&2; return 2; }; name=$1 ;;
        esac
        shift
    done
    [ -n "$name" ] || { box_usage >&2; return 2; }
    tmux has-session -t "=$name" 2>/dev/null || { echo "sala box: no live session '$name'" >&2; return 2; }
    pane=$(tmux list-panes -t "$(tmux_win_t "$name")" -F '#{pane_id}' 2>/dev/null | head -1)
    [ -n "$pane" ] || { echo "sala box: session '$name' has no tmux pane" >&2; return 2; }
    is_sleeping "$name" && { echo "sala box: '$name' is sleeping: no claude is running in its pane, so there is no input box to read" >&2; return 3; }
    cpid=$(claude_pid_under "$(tmux display -p -t "$pane" '#{pane_pid}' 2>/dev/null)" 2>/dev/null)
    [ -n "$cpid" ] || { echo "sala box: no claude in the pane of '$name'" >&2; return 3; }
    typed=$(pane_draft "$pane" "$cpid")
    state=empty; text=""
    if [ -n "$typed" ]; then state=typed; text=$typed
    else
        sugg=$(tmux capture-pane -pe -t "$pane" 2>/dev/null | dim_from_capture)
        if [ -n "$sugg" ]; then state=suggestion; text=$sugg; fi
    fi
    text=${text//[[:cntrl:]]/ }
    if [ "$json" = 1 ]; then
        printf '{"session":%s,"state":"%s","text":%s}\n' "$(_json_str "$name")" "$state" "$(_json_str "$text")"
        return 0
    fi
    case "$state" in
        empty) echo empty ;;
        suggestion) printf 'suggestion\nClaude Code'"'"'s own suggestion, not typed by anyone: %s\n' "$text" ;;
        typed) printf 'typed\n%s\n' "$text" ;;
    esac
}
