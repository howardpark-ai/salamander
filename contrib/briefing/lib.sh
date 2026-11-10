#!/bin/bash
# sala-briefing — shared helpers for the morning digests + release alerts. Delivery = Slack incoming
# webhook (the briefing channel of the owner's Slack workspace); LLM = headless `claude -p` on
# this machine inheriting the claude.ai Google Workspace connector (BRIEFING_GMAIL_CONNECTOR), or reading
# the same mailbox through the owner's MCP Portal when BRIEFING_CLAUDE_CONFIG_DIR
# picks a login without that connector. While the API key has credit (the shared record, lib/api_credit.py) the turn
# runs through the Agent SDK on the key instead, falling back to `claude -p` on a login (see briefing_backend).
#
# Design rule: the LLM only READS mail and WRITES text. The shell owns delivery
# and refuses to post a digest that carries no evidence of a real Gmail call
# (the "fabricated briefing" failure mode) — that alert goes to the
# same channel so silence always means "cron did not run".
#
# Lives in salamander at contrib/briefing/; run by the sala-briefing-* systemd user
# timers (contrib/briefing/systemd/). Also sourced by sala's
# SALA_WATCH_NOTIFY_CMD (post-stdin.sh, which sources it and posts stdin), so it
# only defines things and never exits: safe to source from bash in any
# directory and through a symlink (bash only: it reads BASH_SOURCE).
set -u
# The directory this file really lives in (symlinks resolved), so the scripts
# and their prompt files are found from any checkout.
_bsrc=${BASH_SOURCE[0]:-$0}; [ -L "$_bsrc" ] && _bsrc=$(readlink -f "$_bsrc"); [[ $_bsrc == */* ]] || _bsrc=./$_bsrc   # no dirname/readlink process unless the file is a symlink
BRIEFING_DIR="$(cd -P "${_bsrc%/*}" && pwd -P)"; unset _bsrc
# HOME is the caller's own (a systemd user unit and a login shell both set it); unset, the account's home from the passwd entry.
export HOME=${HOME:-~} LANG=C.UTF-8
export PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
# The briefing's own settings (config.example, "The briefings"): the environment when it sets one, else its line in the sala
# config (SALA_CONFIG, default ~/.config/salamander/config; read, never sourced: briefing_config_value's rules), all read
# by ONE python process and only when the environment leaves one of them unset and a config is there. A path's leading ~ or
# $HOME is the caller's home.
declare -gA _BCFG=()
_bcfg_load() {
  local cfg="${SALA_CONFIG:-$HOME/.config/salamander/config}" v need=() vals=() i
  for v in "$@"; do [ -n "${!v+x}" ] || need+=("$v"); done
  [ ${#need[@]} -gt 0 ] && [ -r "$cfg" ] || return 0
  mapfile -d '' vals < <(python3 -I -c '
import re, shlex, sys
path, names = sys.argv[1], sys.argv[2:]
vals = dict.fromkeys(names, "")
try:
    for line in open(path, encoding="utf-8", errors="replace"):
        for var in names:
            m = re.match(r"\s*(?:export\s+)?" + re.escape(var) + r"=(.*)$", line)
            if m:
                lx = shlex.shlex(m.group(1), posix=True); lx.whitespace_split = True; lx.commenters = ""
                try: vals[var] = lx.get_token() or ""
                except ValueError: pass
except OSError: pass
sys.stdout.write("".join(vals[n] + "\0" for n in names))' "$cfg" "${need[@]}" 2>/dev/null)
  for i in "${!need[@]}"; do _BCFG[${need[$i]}]=${vals[$i]-}; done
}
_bcfg() {  # <VAR> → the environment's value when it sets VAR, else the config's (after _bcfg_load)
  if [ -n "${!1+x}" ]; then printf '%s' "${!1}"; else printf '%s' "${_BCFG[$1]-}"; fi
}
_bhome() { case "$1" in "~"|"~/"*) printf '%s' "$HOME${1#\~}";; '$HOME'|'$HOME/'*) printf '%s' "$HOME${1#\$HOME}";; '${HOME}'|'${HOME}/'*) printf '%s' "$HOME${1#\$\{HOME\}}";; *) printf '%s' "$1";; esac; }
_bcfg_load BRIEFING_WEBHOOK_FILE BRIEFING_LOGDIR BRIEFING_OLD_LOGDIR BRIEFING_GMAIL_CONNECTOR BRIEFING_LEAN_CLIENT_NAME BRIEFING_TZ
# BRIEFING_TZ: the time zone the digests show their times in (an IANA name such as Europe/Paris, or UTC); unset, empty or not a
# plain zone name: UTC. Exported as TZ, so the clock, gmail_fetch.py's dates and the posts' times all read it. The timers' own
# OnCalendar lines carry their zone themselves.
BRIEFING_TZ=$(_bcfg BRIEFING_TZ); [[ $BRIEFING_TZ =~ ^[A-Za-z][A-Za-z0-9_+/-]*$ ]] || BRIEFING_TZ=UTC
export TZ=$BRIEFING_TZ
# BRIEFING_LEAN_CLIENT_NAME: the name gmail_fetch.py gives itself to the portal (MCP clientInfo; its User-Agent is <name>/1).
# Unset or empty: sala-briefing-lean (gmail_fetch.py's own default). Exported for it.
BRIEFING_LEAN_CLIENT_NAME=$(_bcfg BRIEFING_LEAN_CLIENT_NAME); [ -n "$BRIEFING_LEAN_CLIENT_NAME" ] && export BRIEFING_LEAN_CLIENT_NAME || unset BRIEFING_LEAN_CLIENT_NAME
# BRIEFING_WEBHOOK_FILE: the Slack incoming-webhook URL's file (secret, mode 600); unset or empty: ~/.config/sala-briefing/slack-webhook
WEBHOOK_FILE=$(_bhome "$(_bcfg BRIEFING_WEBHOOK_FILE)"); WEBHOOK_FILE=${WEBHOOK_FILE:-$HOME/.config/sala-briefing/slack-webhook}   # tests repoint it (tests/briefing/reply.sh)
# BRIEFING_LOGDIR: the run logs. They are state, not cache (XDG); unset or empty: $XDG_STATE_HOME (~/.local/state)/sala-briefing.
# The units append their own output to cron.log here too (BRIEFING_CRON_LOG, below), so they name no directory of their own.
LOGDIR=$(_bhome "$(_bcfg BRIEFING_LOGDIR)"); LOGDIR=${LOGDIR:-${XDG_STATE_HOME:-$HOME/.local/state}/sala-briefing}   # tests repoint it: CI runs as the user ci, who cannot write under the owner's home
# BRIEFING_OLD_LOGDIR: an older log directory that migrate_old_logdir (below) carries over; unset or empty (the default): none.
# A test that repoints BRIEFING_LOGDIR in its environment never reads the config's line, so it never touches a real directory
# unless it names BRIEFING_OLD_LOGDIR itself (tests/briefing/migrate.sh).
if [ -n "${BRIEFING_OLD_LOGDIR:-}" ]; then OLD_LOGDIR=$(_bhome "$BRIEFING_OLD_LOGDIR")
elif [ -z "${BRIEFING_LOGDIR:-}" ]; then OLD_LOGDIR=$(_bhome "$(_bcfg BRIEFING_OLD_LOGDIR)")
else OLD_LOGDIR=; fi
CLAUDE_BIN=${BRIEFING_CLAUDE_BIN:-$HOME/.local/bin/claude}   # tests/briefing/holds.sh runs summary.sh itself, with a fake
MODEL=${SALA_BRIEFING_MODEL:-sonnet}
# BRIEFING_GMAIL_CONNECTOR: the one word that names the mailbox's Google Workspace connector, as claude.ai shows it
# ("Google Workspace <word>"; letters and digits). The digests' tools come from it: the claude.ai connector's
# mcp__claude_ai_Google_Workspace_<word>__<read>, and the portal's own Gmail reads, g<word in lower case>_<read>. Unset,
# empty or not one word: no digest runs (summary.sh, defunct.sh and summary-lean.sh say so on cron.log and exit 0), the
# guard (guard.py) allows no Gmail read, and the counts below find none. Exported: guard.py and gmail_fetch.py read it.
BRIEFING_GMAIL_CONNECTOR=$(_bcfg BRIEFING_GMAIL_CONNECTOR)
[[ $BRIEFING_GMAIL_CONNECTOR =~ ^[A-Za-z0-9]+$ ]] || BRIEFING_GMAIL_CONNECTOR=
export BRIEFING_GMAIL_CONNECTOR
GMAIL_READ_NAMES="search_gmail_messages get_gmail_message_content get_gmail_messages_content_batch get_gmail_thread_content get_gmail_threads_content_batch"
GMAIL_PREFIX=; PORTAL_GMAIL_PREFIX=; GMAIL_TOOLS=; PORTAL_GMAIL_READS=
if [ -n "$BRIEFING_GMAIL_CONNECTOR" ]; then
  GMAIL_PREFIX="mcp__claude_ai_Google_Workspace_${BRIEFING_GMAIL_CONNECTOR}__"
  PORTAL_GMAIL_PREFIX="g${BRIEFING_GMAIL_CONNECTOR,,}_"
  for _r in $GMAIL_READ_NAMES; do GMAIL_TOOLS+=${GMAIL_TOOLS:+,}$GMAIL_PREFIX$_r; PORTAL_GMAIL_READS+=${PORTAL_GMAIL_READS:+ }$PORTAL_GMAIL_PREFIX$_r; done; unset _r
fi
# The same Gmail reads through the owner's MCP Portal: a login without the claude.ai connector reads
# them through the portal, where they are codemode.g<word>_<tool> inside
# portal_codemode_execute. Execute can run any portal tool, so the prompts name only these five reads, and the guard
# (gmail_calls) counts an execute call only when its code calls one of them.
PORTAL_TOOLS="mcp__mcp-portal__portal_codemode_search,mcp__mcp-portal__portal_codemode_execute"
# The read guard: guard.py beside this file is a PreToolUse hook that refuses, before it
# runs, any portal_codemode_execute whose code is not plainly one of the five Gmail reads, and any other MCP tool that
# can write (its header has the rules). run_cli and run_sdk pass it with --settings, so only the digests' own runs load
# it, on either backend; its decisions go to $LOGDIR/guard.log. A refused call never ran: gmail_calls does not count it
# and portal_writes does not report it; portal_refused names it for the digest's footer and cron.log.
GUARD_HOOK=$BRIEFING_DIR/guard.py
GUARD_MARK='[briefing-guard]'   # the first word of every refusal reason guard.py prints; the stream log carries it back
# BRIEFING_CLAUDE_CONFIG_DIR: when set, the digests' claude runs with CLAUDE_CONFIG_DIR set to it, i.e. on that login
# (a second Claude Code config directory). Unset or empty: the caller's own config, as before.
BRIEFING_CLAUDE_CONFIG_DIR=${BRIEFING_CLAUDE_CONFIG_DIR-}
# While the API key has credit the digests run through the Agent SDK on the key (sdk_run.py beside this file), which the credit
# pays for; it refuses `claude -p` with the key ("credit balance is too low"), so it is the real SDK, never a CLI run passed
# off as one. THE CREDIT RECORD: there is no way to read the balance, so the refusal is the signal.
# lib/api_credit.py keeps ${XDG_STATE_HOME:-~/.local/state}/api-credit/state.json: no refusal on record in the last
# API_CREDIT_RETRY_S seconds (6 h) and a readable key file → the SDK on the key; otherwise straight to `claude -p` on the
# login (the unit's lane). sdk_run.py writes the record when the key's call is refused ("credit balance") and removes it when a
# call works. BRIEFING_BACKEND=cli forces the login path. The rule (the run never sees the key) is suspended for the SDK run
# only: sdk_run.py reads the key from API_KEY_FILE itself and puts it only into the env of the CLI process it spawns; `claude -p`
# still never gets it. Tests repoint the clock (BRIEFING_NOW, epoch seconds), the key file and the runner (BRIEFING_SDK_CMD).
if [ -r "$BRIEFING_DIR/../../lib/api-credit.sh" ]; then . "$BRIEFING_DIR/../../lib/api-credit.sh"
else api_credit_ok() { return 0; }; fi   # an export without lib/: the key is tried, and a refusal still falls back
# What a lane puts on a `lane exec` environment that would send the SDK's CLI elsewhere than the key (Bedrock's switch, its
# profile and region and the pinned model ids): the units run on the bedrock lane, and the SDK run must not inherit it.
BRIEFING_SDK_UNSET=(CLAUDE_CODE_USE_BEDROCK AWS_PROFILE AWS_REGION ANTHROPIC_BEDROCK_REGION_PREFIX ANTHROPIC_DEFAULT_OPUS_MODEL
                    ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL ENABLE_PROMPT_CACHING_1H_BEDROCK CLAUDE_CODE_USE_ANTHROPIC_AWS)
API_KEY_FILE=${BRIEFING_API_KEY_FILE:-$HOME/.config/anthropic/api-key}
API_WORKSPACE_FILE=${BRIEFING_API_WORKSPACE_FILE:-$HOME/.config/anthropic/workspace-id}
SDK_MCP_CONFIG=${BRIEFING_SDK_MCP_CONFIG:-$HOME/.config/claude-lanes/api-mcp.json}   # the api lane's: mcp-portal, its OAuth token in ~/.claude
SDK_PIN=claude-agent-sdk==0.2.165   # a smoke-tested version; pinned so a morning never meets a new release
[ -d "$LOGDIR" ] || mkdir -p "$LOGDIR"
# BRIEFING_CRON_LOG=1 (the sala-briefing-* units set it): this process's stdout and stderr are appended to $LOGDIR/cron.log,
# which the units' StandardOutput=append: lines used to do, so a unit names no directory and the log follows BRIEFING_LOGDIR.
# Unset at once, so a child that sources this file (release-watch.sh's briefing_box) does not redirect its own output.
if [ "${BRIEFING_CRON_LOG-}" = 1 ]; then unset BRIEFING_CRON_LOG; exec >>"$LOGDIR/cron.log" 2>&1; fi

# briefing_need_connector <job>  — 0 when BRIEFING_GMAIL_CONNECTOR names the mailbox's connector; else one cron.log line and 1
# (the caller exits 0: no connector set is the briefing switched off, not a failure)
briefing_need_connector() {
  [ -n "$BRIEFING_GMAIL_CONNECTOR" ] && return 0
  cron_log "$1: no digest: BRIEFING_GMAIL_CONNECTOR is not set (config.example, the briefings)"; return 1
}
# briefing_need_label <job>  — 0 when BRIEFING_FORWARD_LABEL names the Gmail label of the defunct-address queue; else one cron.log
# line and 1 (the caller exits 0: no label set is that digest switched off, not a failure)
briefing_need_label() {
  [ -n "$(briefing_label)" ] && return 0
  cron_log "$1: no digest: BRIEFING_FORWARD_LABEL is not set (config.example, the briefings)"; return 1
}
# briefing_owner_load  — sets BRIEFING_OWNER (what the digests call the person who runs this machine: SALA_OWNER_NAME, read by
# briefing_setting, "the owner" when unset or empty) and BRIEFING_GREETING (", <name>" for the greeting line; empty when no name
# is set, so the greeting reads "Good morning!"). Not in a subshell: a caller reads the variables afterwards.
briefing_owner_load() {
  local n; n=$(briefing_setting SALA_OWNER_NAME); n=${n%%$'\n'*}
  n=${n#"${n%%[![:space:]]*}"}; n=${n%"${n##*[![:space:]]}"}
  if [ -n "$n" ] && [ "$n" != "the owner" ]; then BRIEFING_OWNER=$n; BRIEFING_GREETING=", $n"
  else BRIEFING_OWNER="the owner"; BRIEFING_GREETING=; fi
}
# briefing_list <VAR>  — a setting that holds a list of names (comma-separated), for a prompt: the setting's value with its
# line breaks folded into spaces, or "none configured" when it is unset or empty, so the sentence around it still reads.
briefing_list() {
  local v; v=$(briefing_setting "$1"); v=${v//$'\n'/ }
  v=${v#"${v%%[![:space:]]*}"}; v=${v%"${v##*[![:space:]]}"}
  printf '%s' "${v:-none configured}"
}
# briefing_label  — BRIEFING_FORWARD_LABEL: the Gmail label the defunct-address queue reads, as one plain word (letters, digits,
# dot, underscore, dash, slash); anything else, or unset: nothing
briefing_label() {
  local v; v=$(briefing_setting BRIEFING_FORWARD_LABEL)
  [[ $v =~ ^[A-Za-z0-9._/-]+$ ]] && printf '%s' "$v"
  return 0
}
# briefing_prompt <prompt file>  — the prompt's text with {{CONNECTOR}} (the connector's word) and {{PORTAL}} (the portal's
# g<word> prefix of its Gmail reads) filled in from BRIEFING_GMAIL_CONNECTOR, {{OWNER}} / {{GREETING}} from
# briefing_owner_load (read once per process: a caller that runs it in a subshell loads it first), and from settings
# {{WATCHLIST}} (BRIEFING_WATCHLIST: the companies and topics a Google Alert must be about to count; empty: "none configured"),
# {{LOW_PRIORITY_SENDERS}} (BRIEFING_LOW_PRIORITY_SENDERS: senders and kinds of mail that stay low-priority; empty: "none
# configured") and {{FORWARD_LABEL}} (BRIEFING_FORWARD_LABEL, see briefing_label)
briefing_prompt() {
  local t; t=$(<"$1"); [ -n "${BRIEFING_OWNER+x}" ] || briefing_owner_load
  t=${t//'{{CONNECTOR}}'/$BRIEFING_GMAIL_CONNECTOR}; t=${t//'{{PORTAL}}'/${PORTAL_GMAIL_PREFIX%_}}
  local w l f; w=$(briefing_list BRIEFING_WATCHLIST); l=$(briefing_list BRIEFING_LOW_PRIORITY_SENDERS); f=$(briefing_label)   # quoted below: an unquoted & in a replacement would stand for the match
  t=${t//'{{GREETING}}'/"$BRIEFING_GREETING"}; t=${t//'{{OWNER}}'/"$BRIEFING_OWNER"}
  t=${t//'{{WATCHLIST}}'/"$w"}; t=${t//'{{LOW_PRIORITY_SENDERS}}'/"$l"}; t=${t//'{{FORWARD_LABEL}}'/"$f"}; printf '%s\n' "$t"
}

# The clock without a date process: TZ is exported above (BRIEFING_TZ), so printf's %()T reads that zone and %Z names it.
now_local() { printf '%(%Y-%m-%d, %I:%M %p %Z)T\n' -1; }
# cron_log <line>  — one timestamped line on cron.log
cron_log() { printf '%(%F %T)T %s\n' -1 "$1" >> "$LOGDIR/cron.log"; }

# migrate_old_logdir  - carry the old log directory (OLD_LOGDIR, BRIEFING_OLD_LOGDIR) over to $LOGDIR, idempotently. Plain files only, and
# `mv -n`, so nothing already in $LOGDIR is overwritten; a name present in both stays where it is (putting the old
# content in front is not safe: systemd holds cron.log open for append, and a rewrite would orphan that handle). A
# subdirectory (lean/) is walked the same way. Symlinks and anything else are left alone. An old directory that ends up
# empty is removed with rmdir (which refuses a non-empty one). When a run moved something, one cron.log line says how
# many files moved and which names stayed; with nothing left to move the function is silent, so a second run changes nothing.
_migrate_walk() {   # <old dir> <new dir> <relative prefix>; counts into the caller's _mig_moved, names into _mig_left
    local f n rel
    mkdir -p "$2" || return 0
    for f in "$1"/* "$1"/.[!.]*; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        n=${f##*/}; rel=$3$n
        if [ -L "$f" ]; then _mig_left="$_mig_left $rel"
        elif [ -d "$f" ]; then
            if [ -e "$2/$n" ] && [ ! -d "$2/$n" ]; then _mig_left="$_mig_left $rel/"; continue; fi
            _migrate_walk "$f" "$2/$n" "$rel/"; rmdir "$f" 2>/dev/null || true
        elif [ -f "$f" ]; then
            if [ -e "$2/$n" ] || [ -L "$2/$n" ]; then _mig_left="$_mig_left $rel"
            elif mv -n "$f" "$2/$n" 2>/dev/null && [ ! -e "$f" ]; then _mig_moved=$((_mig_moved + 1))
            else _mig_left="$_mig_left $rel"; fi
        else _mig_left="$_mig_left $rel"; fi
    done
    return 0
}
migrate_old_logdir() {
    [ -n "$OLD_LOGDIR" ] && [ -d "$OLD_LOGDIR" ] && [ ! -L "$OLD_LOGDIR" ] && [ "$OLD_LOGDIR" != "$LOGDIR" ] || return 0
    local _mig_moved=0 _mig_left=""
    _migrate_walk "$OLD_LOGDIR" "$LOGDIR" ""
    rmdir "$OLD_LOGDIR" 2>/dev/null || true
    if [ "$_mig_moved" -gt 0 ]; then
        cron_log "migrated $_mig_moved log file(s) from $OLD_LOGDIR to $LOGDIR${_mig_left:+; left in the old directory:$_mig_left}"
    fi
    return 0
}
migrate_old_logdir

# slack_text <text>  — Slack mrkdwn for a post: a word with a `~/` path or a `/**`-style glob (a path, a permission
# rule) is wrapped in inline code, any other `~` becomes the lookalike ∼, then the markdown bold markers are converted
# outside code. Slack reads two `~` on a line as strikethrough and `**` as bold: a post holding a permission glob such as
# `Edit(~/x/**)` struck out the rest of its lines.
slack_text() {
  python3 - "$1" <<'PY'
import re,sys
sys.stdout.reconfigure(encoding='utf-8')
def code_split(s): return re.split(r'(`[^`\n]*`)', s)
def wrap(tok):
    if not tok or tok.isspace(): return tok   # a separator, blank lines included ("\n\n" crashed it)
    m = re.fullmatch(r'(.*?)([,.;:]*)', tok, re.S)
    core, tail = m.group(1), m.group(2)
    if core and re.search(r'~/|/\*|\*/', core): return f'`{core}`{tail}'
    return tok.replace('~', '\u223c')   # a stray ~ ("~3 min"): a lookalike, never half a strikethrough pair
def bold(s): return re.sub(r'\*\*([^*]+)\*\*', r'*\1*', re.sub(r'__\*\*(.*)\*\*__', r'*\1*', s))
t = ''.join(p if p.startswith('`') else ''.join(wrap(w) for w in re.split(r'(\s+)', p)) for p in code_split(sys.argv[1]))
sys.stdout.write(''.join(p if p.startswith('`') else bold(p) for p in code_split(t)))
PY
}

# briefing_sessions  — the live session names for slack_links, as NAME VERSION BRIDGE rows (the shape of `sala spawn --list`).
# From sala's session registry, `sala sessions --json` (a local file read, 0.2 s; every row whose state is not retired is a
# live session): `sala spawn --list` walks every claude process and tmux pane and took 5.3-6.3 s during a recycle (1.7-2.9 s
# otherwise), so its old 5 s cap cut it off and the post lost its session links. The registry carries no
# claude.ai bridge id, so its rows have none; that matters only to an empty SALA_SESSION_URL (a claude.ai link per bridged
# session), which no unit sets. A registry that fails, times out or lists nothing falls back to `sala spawn --list` with a
# 20 s cap. Test overrides: BRIEFING_SESSIONS_CMD (when non-empty it is the whole lookup, rows as above, 5 s cap, the original
# contract), else BRIEFING_REGISTRY_CMD (the registry JSON), BRIEFING_SPAWN_LIST_CMD (the fallback, rows as above) and
# BRIEFING_SPAWN_LIST_CAP (its cap, default 20).
briefing_sessions() {
  local out
  if [ -n "${BRIEFING_SESSIONS_CMD:-}" ]; then timeout 5 $BRIEFING_SESSIONS_CMD 2>/dev/null || true; return 0; fi
  out=$(timeout 10 ${BRIEFING_REGISTRY_CMD:-sala sessions --json} 2>/dev/null | python3 -c '
import json, sys
try: rows = json.load(sys.stdin).get("sessions", [])
except Exception: sys.exit(0)
for r in rows if isinstance(rows, list) else []:
    n = r.get("name") if isinstance(r, dict) else None
    if isinstance(n, str) and n and len(n.split()) == 1 and r.get("state") != "retired": print(n, "-", "-")
' 2>/dev/null) || true
  if [ -n "$out" ]; then printf '%s\n' "$out"; return 0; fi
  timeout "${BRIEFING_SPAWN_LIST_CAP:-20}" ${BRIEFING_SPAWN_LIST_CMD:-sala spawn --list} 2>/dev/null || true
}

# briefing_config_value <config file> <VAR>  — the value of the last plain `VAR=value` line of a sala config, READ, never sourced:
# the config is a shell file and sourcing it would run whatever else it does. The value is parsed as the shell would split the
# word (quotes removed, a trailing comment never read) but nothing is expanded, so `$VAR` or `$(cmd)` stay literal. None found: nothing.
briefing_config_value() {
  python3 -I -c '
import re, shlex, sys
path, var = sys.argv[1:3]
val = ""
try:
    for line in open(path, encoding="utf-8", errors="replace"):
        m = re.match(r"\s*(?:export\s+)?" + re.escape(var) + r"=(.*)$", line)
        if m:
            lx = shlex.shlex(m.group(1), posix=True); lx.whitespace_split = True; lx.commenters = ""
            try: val = lx.get_token() or ""   # the first word only: a trailing comment is never read
            except ValueError: continue
except OSError: pass
sys.stdout.write(val)' "$1" "$2" 2>/dev/null || true
}

# briefing_setting <VAR>  — a briefing setting: the environment when it sets VAR (empty included), else the VAR line of the sala
# config (SALA_CONFIG, default ~/.config/salamander/config; read by briefing_config_value, never sourced), else empty.
briefing_setting() {
  local cfg="${SALA_CONFIG:-$HOME/.config/salamander/config}"
  if [ -n "${!1+x}" ]; then printf '%s' "${!1}"
  elif [ -r "$cfg" ]; then briefing_config_value "$cfg" "$1"
  fi
}

# briefing_box  — the name the posts give this machine ("Details: <log> on <box>"), and the box a CLAUDE.md echo line names
# ("On <box> (…"), which the result drops: SALA_HEARTBEAT_NAME (this machine's fleet name, from the environment or the sala
# config, as briefing_setting reads it), else the hostname. Read once per process (BRIEFING_BOX caches it; a caller may set it).
briefing_box() {
  if [ -z "${BRIEFING_BOX:-}" ]; then
    BRIEFING_BOX=$(briefing_setting SALA_HEARTBEAT_NAME)
    [ -n "$BRIEFING_BOX" ] || BRIEFING_BOX=$(hostname 2>/dev/null || uname -n)
  fi
  printf '%s' "$BRIEFING_BOX"
}

# slack_links <text>  — Slack links (`<url|text>`) for what a post names, so each opens in one click: a
# session (from sala's session registry, see briefing_sessions), a board id on the board, `<repo>#N`, a commit in a repo of BRIEFING_COMMIT_REPOS, a
# brain-page slug, and the digests' `[gmail:<threadId>]` markers. Whole tokens only, longest session name first; code spans,
# existing links and URLs are left alone, and a name it cannot confirm stays plain. No model, no network: one local
# `sala` call (the registry, 10 s cap; `sala spawn --list`, 20 s cap, only as the fallback), one directory listing, `git cat-file`. Tests repoint the three sources with the BRIEFING_* variables.
# A session links to sala's own session link (sala's session_url): every live
# session (a registry row not retired, or a row of `sala spawn --list`), with or without a claude.ai bridge, so every listed name links, not only the
# bridged ones. The template is resolved without sourcing lib/common.sh (it defines and runs things): SALA_SESSION_URL when
# set (empty means the claude.ai link of a bridged session, as in session_url), else the SALA_SESSION_URL line of the sala
# config (SALA_CONFIG, default ~/.config/salamander/config; read by briefing_config_value, never sourced), else none: sala's
# own default names no web UI, so a box that sets no session link gets the claude.ai link or plain names. The units do not
# set the variable themselves, so they read the config. The encoding is session_url's (tests/briefing/links.sh
# compares the two on awkward names).
# The board and the repos come the same way: BRIEFING_BOARD_DIR (the board's data directory, board-data/<letter>/<n>.json)
# and BRIEFING_COMMIT_REPOS (space-separated name=path pairs, e.g. "salamander=$HOME/salamander") from the environment
# when set (empty too), else their lines in the sala config (config.example), else empty. The board's web address, where
# a board id links to (<address>/items/<id>), is sala's own SALA_STACKSHOT_WEB, read the same way. Empty or missing turns
# that kind of link off: no board links, no commit links, never an error. A leading ~ or $HOME in a path is the caller's home.
# The GitHub links (a page slug, `<repo>#N`, a commit) point into BRIEFING_GITHUB_BASE, read the same way (environment, then the
# config line); unset or empty, none of them is made and those references stay plain text.
slack_links() {
  local sessions tpl board web repos cfg="${SALA_CONFIG:-$HOME/.config/salamander/config}"
  sessions=$(briefing_sessions)   # no sessions: no session links
  if [ -n "${SALA_SESSION_URL+x}" ]; then tpl=$SALA_SESSION_URL
  elif [ -r "$cfg" ]; then tpl=$(briefing_config_value "$cfg" SALA_SESSION_URL)
  else tpl=''; fi
  if [ -n "${BRIEFING_BOARD_DIR+x}" ]; then board=$BRIEFING_BOARD_DIR
  elif [ -r "$cfg" ]; then board=$(briefing_config_value "$cfg" BRIEFING_BOARD_DIR)
  else board=''; fi
  if [ -n "${SALA_STACKSHOT_WEB+x}" ]; then web=$SALA_STACKSHOT_WEB
  elif [ -r "$cfg" ]; then web=$(briefing_config_value "$cfg" SALA_STACKSHOT_WEB)
  else web=''; fi
  if [ -n "${BRIEFING_COMMIT_REPOS+x}" ]; then repos=$BRIEFING_COMMIT_REPOS
  elif [ -r "$cfg" ]; then repos=$(briefing_config_value "$cfg" BRIEFING_COMMIT_REPOS)
  else repos=''; fi
  local issue_repos brain_repo page_dirs github_base
  issue_repos=$(briefing_setting BRIEFING_ISSUE_REPOS); [ -n "${BRIEFING_ISSUE_REPOS+x}" ] || [ -n "$issue_repos" ] || issue_repos="salamander stackshot"
  brain_repo=$(briefing_setting BRIEFING_BRAIN_REPO)
  github_base=$(briefing_setting BRIEFING_GITHUB_BASE)
  page_dirs=$(briefing_setting SALA_PAGE_DIRS); page_dirs=${page_dirs:-projects}
  python3 - "$1" "$sessions" "$board" "$repos" "$tpl" "$(briefing_setting BRIEFING_GMAIL_ACCOUNT)" "$web" "$issue_repos" "$brain_repo" "$page_dirs" "$github_base" <<'PY'
import re,subprocess,sys
sys.stdout.reconfigure(encoding='utf-8')
text, sessions_out, board_dir, repos_spec, tpl, gmail_account, board_web, issue_repos, brain_repo, page_dirs, github_base = sys.argv[1:12]
board_web = board_web.strip().rstrip('/')
def home_path(p):   # a config line is never expanded: a leading ~ or $HOME is the caller's home
    import os
    for pre in ('${HOME}', '$HOME'):
        if p == pre or p.startswith(pre + '/'): p = '~' + p[len(pre):]
    return os.path.expanduser(p) if p else p
board_dir = home_path(board_dir)
# BRIEFING_GITHUB_BASE: the GitHub account a repo link points into, e.g. https://github.com/example-org (a trailing / is dropped; its last
# path segment is the owner). Unset, empty or not a URL ending in an owner: GH is '' and no GitHub link is made (a page slug, `<repo>#N`
# and a commit stay plain, the owner-prefixed form `<owner>/<repo>#N` too)
github_base = github_base.strip().rstrip('/')
_m = re.fullmatch(r'https?://[A-Za-z0-9.-]+(?::[0-9]+)?(?:/[A-Za-z0-9._~-]+)*/(?P<owner>[A-Za-z0-9._-]+)', github_base)
GH, GH_OWNER = (github_base, _m.group('owner')) if _m else ('', '')
from urllib.parse import quote as _q   # BRIEFING_GMAIL_ACCOUNT picks the signed-in account; unset: the first one (u/0)
GMAIL = ('https://mail.google.com/mail/u/?authuser=' + _q(gmail_account, safe='@.+') if gmail_account
         else 'https://mail.google.com/mail/u/0/') + '#all/'
sessions = {}   # NAME VERSION BRIDGE rows: name -> its claude.ai bridge id, '' when the row has none (it still links, to sala)
for row in sessions_out.splitlines():
    f = row.split()
    if f and f[0] not in ('NAME', '?'):
        sessions[f[0]] = next((x for x in f[1:] if re.fullmatch(r'session_\w+', x)), '')
def session_url(name, bridge):   # lib/common.sh's SALA_SESSION_URL_PY, the same encoding (encodeURIComponent's unreserved set)
    from urllib.parse import quote
    if tpl: return tpl.replace('{name}', quote(name, safe="-_.!~*'()"))
    return 'https://claude.ai/code/session_' + bridge.split('_', 1)[1] if '_' in bridge else ''
import os   # every item has a board-data/<letter>/<n>.json (board.md lists only the recent ones)
try: board = {l + f[:-5] for l in os.listdir(board_dir) if re.fullmatch(r'[a-z]', l)
              for f in os.listdir(os.path.join(board_dir, l)) if re.fullmatch(r'[0-9]+\.json', f)}
except OSError: board = set()   # no board data: ids stay plain
if not board_web or re.search(r'[<>|\s]', board_web): board = set()   # no usable board web address: ids stay plain
repos = [(n, home_path(p)) for n, p in (r.split('=', 1) for r in repos_spec.split() if '=' in r) if p]
commits = {}
def commit_repo(sha):   # the first repo that has this commit, else None
    if sha not in commits:
        commits[sha] = None
        for name, path in repos:
            try: found = subprocess.run(['git', '-C', path, 'cat-file', '-e', sha + '^{commit}'],
                                        capture_output=True, timeout=5).returncode == 0
            except Exception: found = False
            if found: commits[sha] = name; break
    return commits[sha]
def gmail(m):   # a well-formed marker becomes an `open` link; a malformed one is dropped
    tid = m.group(1)
    return f' <{GMAIL}{tid}|open>' if re.fullmatch(r'[0-9a-fA-F]+', tid) else ''
L, R = r'(?<![A-Za-z0-9./#@-])', r'(?![A-Za-z0-9/#@-]|\.[A-Za-z0-9])'   # a whole token, never part of a longer name
names = '|'.join(re.escape(n) for n in sorted(sessions, key=len, reverse=True)) or '(?!)'   # (?!): no session matches
# a page slug links into the brain's repo (BRIEFING_BRAIN_REPO; none set: no slug links), its dirs SALA_PAGE_DIRS plus the
# people and companies pages; `<repo>#N` links an issue of a repo in BRIEFING_ISSUE_REPOS (default: salamander stackshot)
brain_repo = brain_repo.strip() if re.fullmatch(r'[A-Za-z0-9._-]+', brain_repo.strip()) else ''
dirs = sorted({d for d in page_dirs.split() + ['projects', 'people', 'companies'] if re.fullmatch(r'[a-z0-9-]+', d)})
irepos = [r for r in issue_repos.split() if re.fullmatch(r'[A-Za-z0-9._-]+', r)]
if not GH: brain_repo, irepos = '', []   # no GitHub account: no GitHub link of any kind
SLUG = (r'(?P<slug>(?:' + '|'.join(map(re.escape, dirs)) + r')/[a-z0-9]+(?:[-/][a-z0-9]+)*)(?P<md>\.md)?|') if brain_repo else ''
REPO = (r'|(?:' + re.escape(GH_OWNER) + r'/)?(?P<repo>' + '|'.join(map(re.escape, irepos)) + r')#(?P<num>[0-9]+)') if irepos else ''
TOKEN = re.compile(L + r'(?:' + SLUG + r'(?!)' + REPO +
                   f'|(?P<sess>{names})' r'|(?P<word>[a-z0-9]+))' + R)
def link(m):
    t, gd = m.group(0), m.groupdict()   # a group the pattern leaves out (no brain repo, no issue repo) reads None
    g = gd.get
    if g('slug'): return f'<{GH}/{brain_repo}/blob/main/{g("slug")}.md|{t}>'
    if g('repo'): return f'<{GH}/{g("repo")}/issues/{g("num")}|{t}>'
    if g('sess'):
        u = session_url(t, sessions[t])
        return f'<{u}|{t}>' if u and not re.search(r'[<>|\s]', u) else t   # no usable link (a template gone odd): plain
    if t in board:   # the store id g<N> is item board#N: the link shows and opens the shown id
        return f'<{board_web}/items/{t[1:]}|board#{t[1:]}>' if re.fullmatch(r'g[0-9]+', t) else f'<{board_web}/items/{t}|{t}>'
    if GH and re.fullmatch(r'(?=[0-9a-f]*[0-9])(?=[0-9a-f]*[a-f])[0-9a-f]{7,40}', t) and commit_repo(t):
        return f'<{GH}/{commit_repo(t)}/commit/{t}|{t}>'
    return t
CODE = r'(`[^`\n]*`)'                                     # the code spans slack_text sees
KEEP = re.compile(CODE + r'|(<[^<>\n]*>|https?://[^\s<>`]+)')   # plus Slack links and bare URLs: never linked into
t = ''.join(p if re.fullmatch(CODE, p) else re.sub(r'[ \t]*\[gmail:([^\]\n]*)\]', gmail, p) for p in re.split(CODE, text))
sys.stdout.write(''.join(p if KEEP.fullmatch(p) else TOKEN.sub(link, p) for p in re.split(KEEP, t) if p))
PY
}

# sala_board_links (lib/boardlinks.sh in this checkout, the one implementation sala's own posts run): each bare board#N in a
# post becomes a link to its item at SALA_STACKSHOT_WEB. Missing (a copy of contrib/briefing alone): the text goes as it is.
if [ -r "$BRIEFING_DIR/../../lib/boardlinks.sh" ]; then . "$BRIEFING_DIR/../../lib/boardlinks.sh"; else sala_board_links() { cat; }; fi

# briefing_webhook_file  — prints the webhook file a post goes to. A post may name a channel (a short name matching [a-z0-9-]+):
# BRIEFING_CHANNEL, else SALA_NOTIFY_CHANNEL (sala's notify command gets it from `salamander alert --channel`). The channel's own
# file is BRIEFING_WEBHOOK_FILE_<NAME> (NAME = the channel in capitals, dashes turned into underscores; the environment, else the
# sala config), used only when that file exists and holds something. No channel, a name that does not match, the setting unset or
# empty, or its file missing or blank: the default WEBHOOK_FILE, so a webhook that is not there yet loses no post.
briefing_webhook_file() {
  local ch=${BRIEFING_CHANNEL:-${SALA_NOTIFY_CHANNEL:-}} var f
  if [[ $ch =~ ^[abcdefghijklmnopqrstuvwxyz0123456789-]+$ ]]; then   # spelled out: a-z can match accented letters in some locales
    var=${ch^^}; var=BRIEFING_WEBHOOK_FILE_${var//-/_}
    [ -n "${_BCFG[$var]+x}" ] || _bcfg_load "$var"
    f=$(_bhome "$(_bcfg "$var")")
    if [ -n "$f" ] && grep -q '[^[:space:]]' "$f" 2>/dev/null; then printf '%s' "$f"; return 0; fi
  fi
  printf '%s' "$WEBHOOK_FILE"
}

# post_slack <text>  — posts slack_text <text>, then slack_links and sala_board_links, to the webhook (briefing_webhook_file: the
# default one, or the channel's). With BRIEFING_THREAD_TS set (reply.sh),
# the post is a reply in that message's thread: the payload gains "thread_ts", which incoming webhooks honour (checked
# live). Unset or empty, the payload is the same as before. With BRIEFING_NO_POST set and non-empty (a test
# run by hand) the finished text goes to $LOGDIR/would-post.log instead and the webhook is never read.
post_slack() {
  local text linked
  text=$(slack_text "$1") && [ -n "$text" ] || text=$1   # a formatter failure never costs the post
  linked=$(slack_links "$text") && [ -n "$linked" ] && text=$linked   # nor a linker failure: the unlinked text goes
  linked=$(printf '%s\n' "$text" | sala_board_links "$(briefing_setting SALA_STACKSHOT_WEB)") && [ -n "$linked" ] && text=$linked   # each bare board#N: a link to its item
  if [ -n "${BRIEFING_NO_POST-}" ]; then printf '%s\n' "$text" >> "$LOGDIR/would-post.log"; echo "not posted (BRIEFING_NO_POST)"; return 0; fi
  python3 - "$text" "$(cat "$(briefing_webhook_file)")" "${BRIEFING_THREAD_TS-}" <<'PY'
import json,sys,urllib.request
text,url,ts=sys.argv[1],sys.argv[2],sys.argv[3]
payload={"text":text,"unfurl_links":False,"unfurl_media":False}
if ts: payload["thread_ts"]=ts
req=urllib.request.Request(url,data=json.dumps(payload).encode(),headers={"Content-Type":"application/json"})
with urllib.request.urlopen(req,timeout=20) as r: print(r.read().decode())
PY
}

# guard_settings  — the settings JSON that loads guard.py as a PreToolUse hook on every mcp__ tool of one run, for
# `--settings` (claude -p takes a JSON string; the SDK's `settings` option hands it to the same flag). Absolute paths,
# shell-quoted, so the hook runs from any cwd; the log beside the stream logs.
guard_settings() {
  python3 - "$GUARD_HOOK" "$LOGDIR/guard.log" <<'PY'
import json,shlex,sys
cmd = "python3 -I " + shlex.quote(sys.argv[1]) + " --log " + shlex.quote(sys.argv[2])
print(json.dumps({"hooks": {"PreToolUse": [{"matcher": "mcp__.*", "hooks": [{"type": "command", "command": cmd, "timeout": 20}]}]}}))
PY
}

# briefing_backend  — prints sdk or cli: sdk when the key file is readable and the credit record holds no refusal less than
# API_CREDIT_RETRY_S old (api_credit_ok), unless BRIEFING_BACKEND=cli. BRIEFING_NOW is the tests' clock.
briefing_backend() {
  [ "${BRIEFING_BACKEND-}" = cli ] && { echo cli; return; }
  [ -r "$API_KEY_FILE" ] && api_credit_ok "${BRIEFING_NOW:-}" && echo sdk || echo cli
}

# run_sdk <log> <prompt> [<job>]  — the turn through sdk_run.py on the key, same model, tools and 600 s cap as the
# `claude -p` call, its stream-json lines in <log> and stderr in <log>.err. The shell passes no key variable (they are
# unset here) and no CLAUDE_CONFIG_DIR, so the CLI under the SDK uses ~/.claude, where the portal's OAuth token is; nor
# the lane's own routing (BRIEFING_SDK_UNSET). <job> names the run in the credit record sdk_run.py writes on a refusal.
run_sdk() {
  local log=$1 prompt=$2 job=${3:-briefing} cmd ufl=() v
  for v in "${BRIEFING_SDK_UNSET[@]}"; do ufl+=(-u "$v"); done
  cmd=(uv run --quiet --no-project --with "$SDK_PIN" python -I "$BRIEFING_DIR/sdk_run.py")
  [ -n "${BRIEFING_SDK_CMD-}" ] && read -ra cmd <<< "$BRIEFING_SDK_CMD"
  printf '%s' "$prompt" | timeout 600 env -u ANTHROPIC_API_KEY -u ANTHROPIC_CUSTOM_HEADERS -u CLAUDE_CONFIG_DIR "${ufl[@]}" \
      "${cmd[@]}" --model "$MODEL" --allowed-tools "$GMAIL_TOOLS,$PORTAL_TOOLS" --settings "$(guard_settings)" \
      --mcp-config "$SDK_MCP_CONFIG" --mcp-server mcp-portal --by "briefing $job" \
      --key-file "$API_KEY_FILE" --workspace-file "$API_WORKSPACE_FILE" > "$log" 2>"$log.err"
}

# run_cli <log> <prompt>  — the turn on a login with `claude -p` (the fallback path, and the only one while the credit record holds a refusal).
# The claude it runs never sees ANTHROPIC_API_KEY or ANTHROPIC_CUSTOM_HEADERS: with the
# key, claude bills the key and loads no claude.ai connector, so this path always runs on a login, never the key.
run_cli() {
  local log=$1 prompt=$2
  local cfg=()
  [ -n "$BRIEFING_CLAUDE_CONFIG_DIR" ] && cfg=("CLAUDE_CONFIG_DIR=$BRIEFING_CLAUDE_CONFIG_DIR")
  timeout 600 env -u ANTHROPIC_API_KEY -u ANTHROPIC_CUSTOM_HEADERS ${cfg[@]+"${cfg[@]}"} \
      "$CLAUDE_BIN" --model "$MODEL" --verbose --output-format stream-json --settings "$(guard_settings)" \
      --allowedTools "$GMAIL_TOOLS,$PORTAL_TOOLS" -p "$prompt" > "$log" 2>"$log.err"
}

# guard_lines  — the number of lines in $LOGDIR/guard.log, 0 when it is missing or unreadable. guard.py appends one line
# per decision (allow or deny), so a run whose portal calls left no new line ran without the read guard.
guard_lines() {
  local f=$LOGDIR/guard.log
  if [ -r "$f" ]; then wc -l < "$f" | tr -d ' '; else echo 0; fi
}

# run_claude <name> <prompt>  — headless turn, stream-json captured to the log.
# Sets: RESULT (final text), GMAIL_CALLS (number of Gmail tool calls), PORTAL_WRITES (see portal_writes), PORTAL_REFUSED
# (see portal_refused; also one cron.log line), RC, BACKEND_USED, and the read guard's load check:
# PORTAL_EXECS (portal_codemode_execute calls of the SDK run and the claude -p rerun together), GUARD_LINES_BEFORE
# (guard_lines before the first attempt; the rerun does not reset it) and GUARD_LINES_GAINED (lines added since).
# Backend per briefing_backend. A failed SDK run (non-zero exit: an error result, no result, an exception, the
# 600 s cap) reruns the same turn with run_cli, logging why to cron.log: "credit balance" in its output means the credit
# is gone (sdk_run.py has written the credit record, so the next runs skip the key for 6 hours), anything else is named by its
# exit and last stderr line. The SDK log is kept beside as <name>.<date>.sdk.jsonl,
# and a write it made still holds the digest back (PORTAL_WRITES is the union of both runs).
run_claude() {
  local name=$1 prompt=$2
  local _ymd; printf -v _ymd '%(%Y%m%d)T' -1
  local log="$LOGDIR/$name.$_ymd.jsonl" sdk_writes="" sdk_refused="" sdk_execs=0 why
  BACKEND_USED=cli
  GUARD_LINES_BEFORE=$(guard_lines)
  if [ "$(briefing_backend)" = sdk ]; then
    run_sdk "$log" "$prompt" "$name"; RC=$?
    if [ "$RC" -eq 0 ]; then BACKEND_USED=sdk
    else
      if grep -qi 'credit balance' "$log" "$log.err" 2>/dev/null; then why="the API credit is used up"
      elif [ "$RC" -eq 124 ]; then why="timed out after 600 s"
      else why="exit $RC: $(grep -v '^\s*$' "$log.err" 2>/dev/null | tail -1 | cut -c1-200)"; fi
      cron_log "$name: Agent SDK run failed ($why); rerunning the turn with claude -p"
      sdk_writes=$(portal_writes "$log"); sdk_refused=$(portal_refused "$log"); sdk_execs=$(portal_execs "$log")
      mv -f "$log" "${log%.jsonl}.sdk.jsonl"; mv -f "$log.err" "${log%.jsonl}.sdk.jsonl.err"
    fi
  fi
  if [ "$BACKEND_USED" = cli ]; then run_cli "$log" "$prompt"; RC=$?; fi
  GMAIL_CALLS=$(gmail_calls "$log")
  PORTAL_WRITES=$(printf '%s\n' $sdk_writes $(portal_writes "$log") | sort -u | xargs)
  PORTAL_REFUSED=$(printf '%s\n' $sdk_refused $(portal_refused "$log") | sort -u | xargs)
  PORTAL_EXECS=$(( sdk_execs + $(portal_execs "$log") ))
  GUARD_LINES_GAINED=$(( $(guard_lines) - GUARD_LINES_BEFORE ))
  [ -n "$PORTAL_REFUSED" ] && cron_log "$name: the read guard refused portal call(s) before they ran: $PORTAL_REFUSED"
  RESULT=$(python3 - "$log" "On $(briefing_box) (" <<'PY'
import json,sys
res=""
for line in open(sys.argv[1],encoding="utf-8"):
    try: d=json.loads(line)
    except Exception: continue
    if d.get("type")=="result": res=d.get("result") or ""
# drop the CLAUDE.md session-start line if the model echoed it
lines=[l for l in res.splitlines() if not l.startswith(sys.argv[2])]
print("\n".join(lines).strip())
PY
)
}

# The three readers of the stream log below share one scan (_STREAM_CALLS, spliced into their unquoted heredocs, which
# therefore hold no `$` of their own): every tool_use block of the assistant messages, each paired with its tool_result
# from the user messages, so a call the read guard refused (its result carries GUARD_MARK, argv[3], and never ran:
# `PreToolUse:<tool> hook error: [briefing-guard] …`) is told apart from one that ran
# An unreadable log gives nothing.
_STREAM_CALLS='
import json,re,sys
def calls(path):
    uses, results = [], {}
    for line in open(path, encoding="utf-8", errors="replace"):
        try: d = json.loads(line)
        except Exception: continue
        if not isinstance(d, dict): continue
        for c in (d.get("message") or {}).get("content") or [] if isinstance(d.get("message"), dict) else []:
            if not isinstance(c, dict): continue
            if d.get("type") == "assistant" and c.get("type") == "tool_use":
                uses.append(c)
            elif d.get("type") == "user" and c.get("type") == "tool_result":
                body = c.get("content")
                if isinstance(body, list): body = " ".join(str(x.get("text", "")) if isinstance(x, dict) else str(x) for x in body)
                results[c.get("tool_use_id")] = str(body or "")
    for c in uses:
        name = c.get("name") or ""
        code = str((c.get("input") or {}).get("code") or "") if isinstance(c.get("input"), dict) else ""
        yield name, code, sys.argv[3] in results.get(c.get("id"), "")
'

# gmail_calls <stream-json log>  — the fabrication guard's count: tool calls of the claude.ai Workspace connector
# (BRIEFING_GMAIL_CONNECTOR), plus portal_codemode_execute calls whose code calls one of the portal's Gmail reads (PORTAL_GMAIL_READS).
# A portal call that reads no Gmail (a search, a label list, another server) does not
# count, nor does a call the read guard refused (it never ran), so a run that never read Gmail is still held back. An
# unreadable log counts 0.
gmail_calls() {
  python3 - "$1" "$PORTAL_GMAIL_READS" "$GUARD_MARK" 2>/dev/null <<PY || echo 0
$_STREAM_CALLS
reads = re.compile(r'\b(?:' + '|'.join(map(re.escape, sys.argv[2].split())) + r')\b' if sys.argv[2].split() else r'(?!)')
n = 0
for name, code, refused in calls(sys.argv[1]):
    if refused: continue
    if "${GMAIL_PREFIX}" and name.startswith("${GMAIL_PREFIX}"): n += 1
    elif name == "mcp__mcp-portal__portal_codemode_execute" and reads.search(code): n += 1
print(n)
PY
}

# portal_writes <stream-json log>  — the portal's g<word>_ tools other than the five Gmail reads that portal_codemode_execute
# calls named in their code AND that ran, sorted, space-separated (empty: none). Rule: every `g<word>_\w+` in the code,
# minus PORTAL_GMAIL_READS, so a send, draft, label, filter, modify, trash or delete tool counts, and so does any Drive,
# Calendar or Docs tool of that server. The read guard (guard.py) refuses such a call before it runs; this is the second
# line, for a call that got past it (a guard that did not load, a path without it): it DETECTS the write after the
# fact, and deliver then holds the digest back and alerts. A refused call is not a write:
# portal_refused reports it. An unreadable log gives none.
portal_writes() {
  python3 - "$1" "$PORTAL_GMAIL_READS" "$GUARD_MARK" 2>/dev/null <<PY || true
$_STREAM_CALLS
reads = set(sys.argv[2].split())
found = set()
for name, code, refused in calls(sys.argv[1]):
    if name == "mcp__mcp-portal__portal_codemode_execute" and not refused:
        found |= set(re.findall(r'${PORTAL_GMAIL_PREFIX}\w+', code) if "${PORTAL_GMAIL_PREFIX}" else []) - reads
print(" ".join(sorted(found)))
PY
}

# portal_refused <stream-json log>  — what the read guard refused: for each refused portal_codemode_execute
# call the g<word>_ names in its code other than the five reads, or `portal_codemode_execute` when it named none (a
# computed name, another server, unreadable code); any other refused mcp__ tool by its short name. Sorted, space-
# separated, empty when nothing was refused. deliver adds them to the digest's footer so a refusal is seen, and
# run_claude writes them to cron.log.
portal_refused() {
  python3 - "$1" "$PORTAL_GMAIL_READS" "$GUARD_MARK" 2>/dev/null <<PY || true
$_STREAM_CALLS
reads = set(sys.argv[2].split())
found = set()
for name, code, refused in calls(sys.argv[1]):
    if not refused: continue
    if name == "mcp__mcp-portal__portal_codemode_execute":
        found |= set(re.findall(r'${PORTAL_GMAIL_PREFIX}\w+', code) if "${PORTAL_GMAIL_PREFIX}" else []) - reads or {"portal_codemode_execute"}
    elif name.startswith("mcp__"):
        found.add(name.split("__", 2)[-1])
print(" ".join(sorted(found)))
PY
}

# portal_execs <stream-json log>  — the number of portal_codemode_execute calls in the log, refused or not: each one
# passes through the read guard, which logs a line for it. An unreadable log counts 0.
portal_execs() {
  python3 - "$1" "" "$GUARD_MARK" 2>/dev/null <<PY || echo 0
$_STREAM_CALLS
print(sum(1 for name, code, refused in calls(sys.argv[1]) if name == "mcp__mcp-portal__portal_codemode_execute"))
PY
}

# run_claude_retry <name> <prompt> — run_claude, retried once after 45 s when the
# Workspace MCP server answers with its OAuth error (observed transient).
AUTH_SENTINEL="Google Workspace ${BRIEFING_GMAIL_CONNECTOR:-(no connector)} connector needs re-authorization."   # the prompts' exact reply
run_claude_retry() {
  run_claude "$1" "$2"
  if [ "$RESULT" = "$AUTH_SENTINEL" ]; then
    cron_log "$1: auth sentinel, retrying in 45s"
    local first_writes=$PORTAL_WRITES   # a write in the first run must still raise the alert after the retry
    local first_refused=$PORTAL_REFUSED first_execs=$PORTAL_EXECS first_before=$GUARD_LINES_BEFORE
    sleep 45; run_claude "$1-retry" "$2"
    PORTAL_WRITES=$(printf '%s\n' $first_writes $PORTAL_WRITES | sort -u | xargs)
    PORTAL_REFUSED=$(printf '%s\n' $first_refused $PORTAL_REFUSED | sort -u | xargs)
    PORTAL_EXECS=$(( first_execs + PORTAL_EXECS ))   # the load check spans both runs, from before the first one
    GUARD_LINES_BEFORE=$first_before; GUARD_LINES_GAINED=$(( $(guard_lines) - GUARD_LINES_BEFORE ))
  fi
}

# fetch_new_holds  — the morning summary's "New holds" data. Runs holds.py, outside the model (which gets no
# stackshot tool, and guard.py stays as it is): it reads stackshot's /client/brief with the machine token itself. Sets
# HOLDS_BLOCK, the framed data block for the prompt ('' when there are no new holds or the fetch failed), and HOLDS_NOTE,
# one line saying why the briefing ran without it ('' when the fetch worked). A failure never fails the briefing; the
# caller appends HOLDS_NOTE to the run's .err log after the run, since the run itself overwrites that file.
# BRIEFING_HOLDS_CMD swaps in a stub (tests); the 20 s cap sits over holds.py's own 15 s one.
fetch_new_holds() {
  local cmd=(python3 -I "$BRIEFING_DIR/holds.py") err rc
  [ -n "${BRIEFING_HOLDS_CMD-}" ] && read -ra cmd <<< "$BRIEFING_HOLDS_CMD"
  HOLDS_BLOCK=""; HOLDS_NOTE=""
  err=$(mktemp "$LOGDIR/holds.XXXXXX") || return 0
  HOLDS_BLOCK=$(timeout 20 "${cmd[@]}" 2>"$err" </dev/null); rc=$?
  if [ "$rc" -ne 0 ]; then
    HOLDS_BLOCK=""
    HOLDS_NOTE="new holds not fetched (exit $rc: $(grep -v '^\s*$' "$err" | tail -1 | cut -c1-200)); the briefing ran without them"
  fi
  rm -f "$err"
}

# deliver <name> <emoji-title>  — post RESULT or a loud failure notice.
deliver() {
  local name=$1 title=$2 _ymd; printf -v _ymd '%(%Y%m%d)T' -1
  if [ -n "${PORTAL_WRITES:-}" ]; then   # first: a write is news whatever else the run did
    post_slack "🚨 *$title held back*
    • the briefing's model called a Google Workspace tool that can write: $PORTAL_WRITES. This was detected after the fact, not prevented: check the mailbox
    • Details: $LOGDIR/$name.$_ymd.jsonl on $(briefing_box)" >/dev/null
    return 1
  fi
  # second: portal calls ran with no read guard watching them. guard.py logs every decision, so a run that made portal
  # calls while guard.log gained no line had no guard loaded. Any line counts, allow or deny: a deny proves
  # the hook ran too, and a run whose every call was refused is the read count's case. A run with no portal call (the
  # direct connector) is not checked.
  if [ "${PORTAL_EXECS:-0}" -gt 0 ] && [ "${GUARD_LINES_GAINED:-0}" -le 0 ]; then
    post_slack "🚨 *$title held back: the read guard did not load*
    • the $name run made $PORTAL_EXECS portal call(s), but $LOGDIR/guard.log gained no line during it, so nothing checked them before they ran; not posted
    • Details: $LOGDIR/$name.$_ymd.jsonl on $(briefing_box)" >/dev/null
    return 1
  fi
  if [ "$RESULT" = "$AUTH_SENTINEL" ]; then
    post_slack "🚨 *$title didn't run*
    • the Google Workspace server rejected the Gmail account$(_acct=$(briefing_setting BRIEFING_GMAIL_ACCOUNT); [ -n "$_acct" ] && printf ' %s' "$_acct") twice: its login needs renewing
    • Details: $LOGDIR/$name.$_ymd.jsonl on $(briefing_box)" >/dev/null
    return 1
  fi
  if [ "$RC" -ne 0 ] || [ -z "$RESULT" ]; then
    post_slack "🚨 *$title failed*
    • $([ -z "$RESULT" ] && echo "the run produced no text" || echo "the run produced text but ended with an error") (claude exit $RC)
    • Details: $LOGDIR/$name.$_ymd.jsonl on $(briefing_box)" >/dev/null
    return 1
  fi
  if [ "$GMAIL_CALLS" -eq 0 ]; then
    post_slack "🚨 *$title held back*
    • it was written without reading Gmail once, so it could be made up; not posted
    • Details: $LOGDIR/$name.$_ymd.jsonl on $(briefing_box)" >/dev/null
    return 1
  fi
  if [ -n "${PORTAL_REFUSED:-}" ]; then   # the digest stands (its reads ran); the refusal is shown under it
    post_slack "$RESULT
⛔ the read guard refused a portal call that was not a Gmail read, before it ran: $PORTAL_REFUSED. Details: $LOGDIR/guard.log on $(briefing_box)" >/dev/null
    return
  fi
  post_slack "$RESULT" >/dev/null
}
