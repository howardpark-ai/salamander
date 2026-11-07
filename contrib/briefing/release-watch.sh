#!/bin/sh
# Unified release watcher: Claude Code CLI, Ubuntu LTS upgrade path.
#
# Runs once a day from release-alert.sh beside it (sala-briefing-release.timer;
# zero LLM cost for the probes). Silent by design:
# prints the NO_REPLY token when nothing is new, which release-alert.sh
# suppresses; only a genuinely new release produces output, which it posts to
# the briefing channel on Slack. Lives in salamander at contrib/briefing/release-watch.sh.
#
# Per product:
#   latest    = what upstream publishes (GitHub "Latest" release / npm dist-tag)
#   installed = what this machine actually runs (the binary / the OS release)
#   deferred  = a tag the owner has already reviewed and parked: while upstream's
#               latest equals it the product stays silent. Set with
#                   release-watch.sh defer <product> [tag]     (default: latest)
#               and cleared automatically once something newer appears.
#   session   = the Claude Code session that owns upgrades for that product; on a
#               new release it is pinged over the documented cross-session channel
#               via a headless `claude -p` turn on the cheapest model (a few
#               hundred tokens, only on release day; through the Agent SDK on the
#               API credit first while the key has credit, see relay_sdk). Best-effort: a failure is
#               reported in the post, never fatal. Empty = no ping.
#
# Exit status: 0 normally; 1 if any upstream/installed probe failed (the post, if
# any, is still printed first) so a broken probe surfaces as a cron error.

set -u
# cron runs with PATH=/usr/bin:/bin; the Claude Code CLI lives in ~/.local/bin, so that must be on PATH.
export HOME=${HOME:-~}   # the caller's own; unset, the account's home from the passwd entry
export PATH="$HOME/.local/bin:$PATH"

STATE=${RELEASE_WATCH_STATE:-$HOME/.release-watch}        # tests repoint both (tests/briefing/sdk.sh)
CLAUDE_BIN=${RELEASE_WATCH_CLAUDE_BIN:-$HOME/.local/bin/claude}
HERE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)   # sdk_run.py lives beside this file
RELAY_CWD=${RELEASE_WATCH_RELAY_CWD:-$HOME}   # where the relay turn runs; tests repoint it (CI's user cannot enter the owner's home)
SALA_CMD=${RELEASE_WATCH_SALA:-sala}                    # asked who the master is (cli_owner); tests repoint it to a fake
# The name the post gives this machine (lib.sh's briefing_box: SALA_HEARTBEAT_NAME, else the hostname) and this script's three
# settings, each from the environment, else its line in the sala config (lib.sh's briefing_setting; config.example, the briefings),
# read in ONE child bash so nothing else of lib.sh (its PATH) reaches this script; its last line is the time zone BRIEFING_TZ names. One value per line; a session name or a
# page key is one word.
#   RELEASE_WATCH_CLI_OWNER     the Claude Code CLI's upgrade owner when sala has no master; unset or empty: nobody is pinged
#   RELEASE_WATCH_UBUNTU_SESSION  the session an Ubuntu LTS upgrade path is relayed to; unset or empty: nobody is pinged
#   RELEASE_WATCH_UBUNTU_PAGE   the project page with the upgrade plan, named in the notice and the ping; unset or empty: none named
_rw=$(bash -c '. "$1/lib.sh" >/dev/null 2>&1; briefing_box; echo; for v in RELEASE_WATCH_CLI_OWNER RELEASE_WATCH_UBUNTU_SESSION RELEASE_WATCH_UBUNTU_PAGE; do briefing_setting "$v" | tr -d " \n"; echo; done; briefing_setting SALA_OWNER_NAME | tr -cd "[:alnum:] ._'"'"'-"; echo; echo "$TZ"' _ "$HERE" 2>/dev/null)
BOX=$(printf '%s\n' "$_rw" | sed -n 1p); [ -n "$BOX" ] || BOX=$(hostname 2>/dev/null || uname -n)
CLI_OWNER=$(printf '%s\n' "$_rw" | sed -n 2p)
UBUNTU_SESSION=$(printf '%s\n' "$_rw" | sed -n 3p)
UBUNTU_PAGE=$(printf '%s\n' "$_rw" | sed -n 4p)
RW_TZ=$(printf '%s\n' "$_rw" | sed -n 6p); [ -n "$RW_TZ" ] || RW_TZ=UTC   # the zone the post shows times in (lib.sh's BRIEFING_TZ, exported there as TZ)
OWNER=$(printf '%s\n' "$_rw" | sed -n 5p); case $OWNER in *[!\ ]*) ;; *) OWNER="the owner";; esac   # what the messages call the person who runs this machine (SALA_OWNER_NAME, as sala's runtime text does)
mkdir -p "$STATE/deferred" "$STATE/notified"
# RELEASE_WATCH_DRY=1: print what would be announced; no session ping, no notified-state write.

# ---- product table --------------------------------------------------------
# name       session       (upgrade owner; "" = no ping)
# claudecode_session: set just before the main loop, from sala (cli_owner; only the cli-owner subcommand asks it too)
ubuntults_session=$UBUNTU_SESSION   # fleet-ops news (RELEASE_WATCH_UBUNTU_SESSION; "" = no ping)

# ---- probes ---------------------------------------------------------------
claudecode_latest()    { /usr/bin/npm view @anthropic-ai/claude-code version 2>/dev/null | tail -1; }
claudecode_installed() { "$CLAUDE_BIN" --version 2>/dev/null | awk '{print $1}'; }
claudecode_notes()     { echo "https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md"; }
claudecode_published() { :; }
claudecode_extra()     { :; }
claudecode_howto()     { echo "sala installs it on its own and relaunches the panes; say \"update the CLI\" to any session if you want it sooner"; }
claudecode_ask()       { echo "read the changelog for anything affecting our hooks, settings, sala or Remote Control and report to ${OWNER}; run the fleet update only on ${OWNER}'s cue."; }

# Ubuntu LTS upgrade path (the project page ubuntults_howto names): Canonical opens the next LTS upgrade by flipping
# `Supported: 1` on that release's entry of meta-release-lts, weeks after its .1 release. The
# download page is NOT the signal; this file is. latest = newest LTS with Supported: 1 (MAJOR.MINOR).
ubuntults_latest() {
  curl -fsSL --max-time 30 https://changelogs.ubuntu.com/meta-release-lts 2>/dev/null |
    awk '/^Version:/{v=$2} /^Supported: 1/{last=v} END{if(last!=""){split(last,a,"."); print a[1]"."a[2]}}'
}
ubuntults_installed() { . /etc/os-release 2>/dev/null; echo "${VERSION_ID:-}"; }
ubuntults_notes()     { echo "https://changelogs.ubuntu.com/meta-release-lts (the flag) - https://ubuntu.com/download/server"; }
ubuntults_published() { :; }
ubuntults_extra()     { :; }
ubuntults_howto()     { echo "the upgrade is a console job${UBUNTU_PAGE:+; the plan is on project page $UBUNTU_PAGE}"; }
ubuntults_ask()       { echo "confirm with \`do-release-upgrade -c\` that the new LTS is now offered and report to ${OWNER}${UBUNTU_PAGE:+ against the open item on project page $UBUNTU_PAGE}; do NOT start the upgrade on your own."; }

label() { case "$1" in claudecode) echo "🛠️ Claude Code CLI";; ubuntults) echo "🐧 Ubuntu LTS upgrade path";; esac; }
# headline per product: "🛠️ *Claude Code CLI 9.9.9 is out*" / "🐧 *Ubuntu 28.04 upgrade path is open*"
headline() { case "$1" in ubuntults) echo "🐧 *Ubuntu $2 upgrade path is open*";; *) l=$(label "$1"); echo "${l%% *} *${l#* } $2 is out*";; esac; }
# local_human <iso> -> "Thu Oct 1st 09:47" (the owner's date form, in the zone RW_TZ)
local_human() {
  d=$(TZ=$RW_TZ date -d "$1" '+%-d' 2>/dev/null) || return 0
  case "$d" in 1|21|31) o=st;; 2|22) o=nd;; 3|23) o=rd;; *) o=th;; esac
  TZ=$RW_TZ date -d "$1" "+%a %b ${d}${o} %H:%M"
}

# ---- defer subcommand -----------------------------------------------------
if [ "${1:-}" = defer ]; then
  P=${2:?usage: release-watch.sh defer <claudecode|ubuntults> [tag]}
  TAG=${3:-$("${P}_latest")}
  [ -n "$TAG" ] || { echo "could not resolve latest tag for $P" >&2; exit 1; }
  printf '%s\n' "$TAG" > "$STATE/deferred/$P"
  echo "$P: $TAG deferred — silent until something newer is published."
  exit 0
fi

# ---- relay to a Claude session ---------------------------------------------
# While the API key has credit (the shared record lib/api_credit.py keeps, ${XDG_STATE_HOME:-~/.local/state}/api-credit/
# state.json; no refusal on record in the last API_CREDIT_RETRY_S seconds, 6 h by default) the relay turn goes first through the
# Agent SDK on the key (sdk_run.py, --output text), which the credit pays for and `claude -p` cannot use. sdk_run.py writes the
# record when the key's call is refused and removes it when one works; the check below is the record's `check` command. The turn needs tools (SendMessage,
# ListAgents: both in the SDK's tool list, checked once), so it is the SDK runner, not a bare Messages API call.
# Any answer but DONE from it (ABSENT included, a failure, the credit gone) reruns the same turn on `claude -p` below, as
# before, and is noted on stderr (release-watch.err). With a refusal on record, BRIEFING_BACKEND=cli or no key file, only
# `claude -p` runs, exactly as before. The key is read by sdk_run.py and goes only into its CLI's env. The units run this on the
# bedrock lane, whose routing variables the SDK run must not inherit (the same list as lib.sh's BRIEFING_SDK_UNSET).
SDK_UNSET="-u CLAUDE_CODE_USE_BEDROCK -u AWS_PROFILE -u AWS_REGION -u ANTHROPIC_BEDROCK_REGION_PREFIX -u ANTHROPIC_DEFAULT_OPUS_MODEL -u ANTHROPIC_DEFAULT_SONNET_MODEL -u ANTHROPIC_DEFAULT_HAIKU_MODEL -u ENABLE_PROMPT_CACHING_1H_BEDROCK -u CLAUDE_CODE_USE_ANTHROPIC_AWS"
API_KEY_FILE=${BRIEFING_API_KEY_FILE:-$HOME/.config/anthropic/api-key}
API_WORKSPACE_FILE=${BRIEFING_API_WORKSPACE_FILE:-$HOME/.config/anthropic/workspace-id}
relay_sdk() { # relay_sdk <prompt>  -> the SDK turn's last line; status 1 (no output) when the key is not to be tried
  [ "${BRIEFING_BACKEND:-}" != cli ] && [ -r "$API_KEY_FILE" ] || return 1
  python3 -I "$HERE/../../lib/api_credit.py" check ${BRIEFING_NOW:+--now "$BRIEFING_NOW"} 2>/dev/null || [ "$?" -ne 1 ] || return 1   # 1: a refusal is fresh; any other failure of the check tries the key
  if [ -n "${BRIEFING_SDK_CMD:-}" ]; then set -- "$1" $BRIEFING_SDK_CMD   # tests: a fake runner
  else set -- "$1" uv run --quiet --no-project --with claude-agent-sdk==0.2.165 python -I "$HERE/sdk_run.py"; fi
  RP=$1; shift
  printf '%s' "$RP" | (cd "$RELAY_CWD" || exit 1; timeout 180 env -u ANTHROPIC_API_KEY -u ANTHROPIC_CUSTOM_HEADERS -u CLAUDE_CONFIG_DIR $SDK_UNSET \
      "$@" --model haiku --allowed-tools "SendMessage,ListAgents" --output text --by release-watch \
      --key-file "$API_KEY_FILE" --workspace-file "$API_WORKSPACE_FILE" 2>/dev/null) | tail -1
  return 0
}
relay() { # relay <session> <message>  -> prints a status line
  # A front agent (a session named *-main) takes a message only when its FIRST line is `[for <owner>]`; anything else is logged, never
  # read. So a *-main recipient gets that line first.
  RMSG=$2
  case "$1" in *-main) RMSG="[for ${OWNER}]
$2";; esac
  RPROMPT="Send exactly this cross-session message to the local Claude session named \"$1\" using SendMessage, line breaks kept, then reply with the single word DONE. If no such session is listed by ListAgents, reply with the single word ABSENT. Message: \"$RMSG\""
  if OUT=$(relay_sdk "$RPROMPT"); then
    [ "$OUT" = DONE ] && { echo "$1 has been told and will report"; return; }
    echo "relay: the Agent SDK turn answered '${OUT:-nothing}'; rerunning it with claude -p" >&2
  fi
  [ -x "$CLAUDE_BIN" ] || { echo "⚠️ couldn't reach $1 (claude CLI missing), so nobody was told"; return; }
  OUT=$(cd "$RELAY_CWD" && timeout 180 "$CLAUDE_BIN" --model haiku \
        --allowedTools "SendMessage,ListAgents" \
        -p "$RPROMPT" 2>/dev/null | tail -1)
  case "$OUT" in
    DONE)   echo "$1 has been told and will report" ;;
    ABSENT) echo "⚠️ $1 isn't running, so nobody was told" ;;
    *)      echo "⚠️ couldn't reach $1, so nobody was told" ;;
  esac
}

# ---- relay subcommand -------------------------------------------------------
# release-watch.sh relay <session> <message>: one relay by hand (and the tests' handle on it); prints the status line.
if [ "${1:-}" = relay ]; then relay "${2:?usage: release-watch.sh relay <session> <message>}" "${3:?message}"; exit 0; fi

# CLI updates are the sala master's; who that is comes from sala, never a
# hard-coded name. With no master (`sala master` prints "no master: …", so the lookup is empty) the owner is CLI_OWNER (RELEASE_WATCH_CLI_OWNER, above),
# who queues the fleet update through `sala op`; with that unset too, nobody is pinged.
cli_owner() {
  m=$("$SALA_CMD" master 2>/dev/null | awk '$1=="master"{print $3; exit}')
  echo "${m:-$CLI_OWNER}"
}
# release-watch.sh cli-owner: the session a new Claude Code release is relayed to (and the tests' handle on it).
if [ "${1:-}" = cli-owner ]; then cli_owner; exit 0; fi
claudecode_session=$(cli_owner)

# ---- main loop --------------------------------------------------------------
OUT=""
FAIL=0
for P in claudecode ubuntults; do
  LATEST=$("${P}_latest"); INSTALLED=$("${P}_installed")
  if [ -z "$LATEST" ] || [ -z "$INSTALLED" ]; then
    if [ -z "$LATEST" ]; then echo "$(label "$P"): couldn't read the latest release upstream" >&2
    else echo "$(label "$P"): couldn't read the version $BOX runs (latest is $LATEST)" >&2; fi
    FAIL=1; continue
  fi
  BLOCK=$("${P}_extra" "$LATEST" "$INSTALLED")
  if [ "${LATEST#v}" != "${INSTALLED#v}" ]; then
    DEFERRED=$(cat "$STATE/deferred/$P" 2>/dev/null || true)
    if [ -n "$DEFERRED" ] && [ "${DEFERRED#v}" = "${LATEST#v}" ]; then
      : # reviewed and parked by the owner — stay quiet
    else
      [ -n "$DEFERRED" ] && rm -f "$STATE/deferred/$P"   # something newer: un-park
      PUB=$("${P}_published" "$LATEST")
      [ -n "$PUB" ] && PUB=$(local_human "$PUB")
      NEW="$(headline "$P" "$LATEST")
    • $BOX runs $INSTALLED${PUB:+ · published $PUB}
    • $("${P}_howto")
    • <$("${P}_notes" "$LATEST" | awk '{print $1}')|Release notes>"
      # once per release: a tag already announced stays quiet on later runs (the deferred list
      # still parks a tag the owner reviewed; a newer tag announces again)
      if [ "$(cat "$STATE/notified/$P" 2>/dev/null)" = "$LATEST" ]; then
        [ -n "$BLOCK" ] && OUT="${OUT:+$OUT

}$BLOCK"
        continue
      fi
      [ "${RELEASE_WATCH_DRY:-0}" = 1 ] || printf '%s\n' "$LATEST" > "$STATE/notified/$P"
      eval "SESSION=\${${P}_session}"
      if [ -n "$SESSION" ] && [ "${RELEASE_WATCH_DRY:-0}" = 1 ]; then
        NEW="$NEW
    • (dry run: would ping $SESSION)"
      elif [ -n "$SESSION" ]; then
        NEW="$NEW
    • $(relay "$SESSION" "release watcher: new $(label "$P") release $LATEST is out ($BOX runs $INSTALLED). Release notes: $("${P}_notes" "$LATEST") — $("${P}_ask")")"
      fi
      BLOCK="${NEW}${BLOCK:+
$BLOCK}"
    fi
  fi
  [ -n "$BLOCK" ] && OUT="${OUT:+$OUT

}$BLOCK"
done

if [ -n "$OUT" ]; then printf '%s\n' "$OUT"; else echo NO_REPLY; fi
exit $FAIL
