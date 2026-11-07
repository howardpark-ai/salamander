#!/usr/bin/env bash
# install.sh [--web] — symlink bin/salamander into ~/.local/bin, seed the config, print the tmux
# hook lines. Idempotent. Nothing here touches ~/.tmux.conf or ~/.claude for you.
# --web: also copy the web UI's three systemd user units (sala-web.socket, sala-web.service, sala-web-ttyd.service, from web/contrib/)
# into $XDG_CONFIG_HOME/systemd/user (default ~/.config/systemd/user), with this checkout's path in place of %h/salamander.
# It starts nothing and enables nothing; the commands to run next are printed (docs/web-proxy.md has the login in front).
# An install whose web units still have their old name is migrated (lib/webunits.sh), with or without --web.
set -eu
WEB=0
for a in "$@"; do
  case "$a" in
    --web) WEB=1 ;;
    -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install.sh: unknown option $a (usage: install.sh [--web])" >&2; exit 2 ;;
  esac
done
ROOT=$(cd "$(dirname "$0")" && pwd)
BIN="${BIN_DIR:-$HOME/.local/bin}"; CFG="$HOME/.config/salamander/config"
mkdir -p "$BIN" "$(dirname "$CFG")"
ln -sfn "$ROOT/bin/salamander" "$BIN/salamander"; ln -sfn "$ROOT/bin/salamander" "$BIN/sala"
[ -e "$CFG" ] || cp "$ROOT/config.example" "$CFG"
# compact.tsv (the sessions with a compact window of their own): seeded once, never overwritten; hand-edited after that
CMPT="${XDG_STATE_HOME:-$HOME/.local/state}/salamander/compact.tsv"
[ -e "$CMPT" ] || { mkdir -p "$(dirname "$CMPT")" && cp "$ROOT/contrib/compact.tsv" "$CMPT"; }
[ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 4 ]; } || echo "⚠ bash >= 4.4 needed (this is $BASH_VERSION); bin/salamander refuses to run on an older one"
# The lane awsplatform was renamed aws-platform (Mon Oct 26th 2026). Every reader accepts the old name, so nothing needs this; it rewrites the
# old name in sala's files once (idempotent: a second run, or a box that never had the lane, finds nothing; a backup beside each file it changes).
out=$("$ROOT/bin/salamander" lane --migrate 2>&1) && { case "$out" in nothing*) ;; *) echo "$out";; esac; } \
  || echo "⚠ salamander lane --migrate did not run through (the old lane name awsplatform is still read as aws-platform everywhere): $out"
for dep in tmux python3 claude; do command -v "$dep" >/dev/null || echo "⚠ missing: $dep"; done
# A terminal-only prompt (feedback-draft review, survey) holds a pane that nobody is watching; recycle
# sends queued drafts itself, but the settings must keep them from becoming modal prompts.
python3 -c "import json,os,sys; d=json.load(open(os.path.expanduser('~/.claude/settings.json'),encoding='utf-8')); sys.exit(0 if d.get('feedbackDrafts')=='quiet' and d.get('feedbackSurveyRate')==0 else 1)" 2>/dev/null \
  || echo '⚠ ~/.claude/settings.json: set "feedbackDrafts": "quiet" and "feedbackSurveyRate": 0 — no terminal-only prompts on headless panes'
# Auto-send needs two hooks: PostToolUse(SendFeedback) → `salamander feedback mark`, Stop → `salamander feedback stop`.
python3 -c "
import json,os,sys; h=json.load(open(os.path.expanduser('~/.claude/settings.json'),encoding='utf-8')).get('hooks',{})
def has(ev,frag): return any(frag in c.get('command','') for x in h.get(ev,[]) for c in x.get('hooks',[]))
sys.exit(0 if has('PostToolUse','feedback mark') and has('Stop','feedback stop') else 1)" 2>/dev/null \
  || cat <<'HOOKS'
⚠ feedback auto-send hooks missing — add to ~/.claude/settings.json "hooks":
   "PostToolUse": [{"matcher": "SendFeedback", "hooks": [{"type": "command", "command": "salamander feedback mark"}]}],
   "Stop":        [{"matcher": "*",            "hooks": [{"type": "command", "command": "salamander feedback stop"}]}]
HOOKS
# The busy check's exact answer and the relaunch-waiting line (lib/hook.sh) need two more: Stop → `salamander hook stop`,
# PostToolUse (every tool) → `salamander hook post-tool`. The machine spec registers them; this only says when they are missing.
python3 -c "
import json,os,sys; h=json.load(open(os.path.expanduser('~/.claude/settings.json'),encoding='utf-8')).get('hooks',{})
def has(ev,frag): return any(frag in c.get('command','') for x in h.get(ev,[]) for c in x.get('hooks',[]))
sys.exit(0 if has('Stop','hook stop') and has('PostToolUse','hook post-tool') else 1)" 2>/dev/null \
  || cat <<'HOOKS'
⚠ busy-check hooks missing — add to ~/.claude/settings.json "hooks" (the spec item registers them):
   "Stop":        [{"matcher": "*", "hooks": [{"type": "command", "command": "~/.local/bin/salamander hook stop"}]}],
   "PostToolUse": [{"matcher": "*", "hooks": [{"type": "command", "command": "~/.local/bin/salamander hook post-tool"}]}]
HOOKS
# `sala notice` (lib/notice.sh) reaches a session at its next tool call through the post-tool hook above, and at its next prompt
# through UserPromptSubmit → `salamander hook prompt` (no matcher: that event takes none); the spec registers it, this says when it is missing.
python3 -c "
import json,os,sys; h=json.load(open(os.path.expanduser('~/.claude/settings.json'),encoding='utf-8')).get('hooks',{})
sys.exit(0 if any('hook prompt' in c.get('command','') for x in h.get('UserPromptSubmit',[]) for c in x.get('hooks',[])) else 1)" 2>/dev/null \
  || cat <<'HOOKS'
⚠ notice hook missing — add to ~/.claude/settings.json "hooks" (the spec item registers it; a notice still reaches a session at its next tool call without it):
   "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "~/.local/bin/salamander hook prompt"}]}]
HOOKS
# The subagent cleanup (lib/hook.sh): SubagentStop → `salamander hook subagent-stop`, registered by the machine spec too.
python3 -c "
import json,os,sys; h=json.load(open(os.path.expanduser('~/.claude/settings.json'),encoding='utf-8')).get('hooks',{})
sys.exit(0 if any('hook subagent-stop' in c.get('command','') for x in h.get('SubagentStop',[]) for c in x.get('hooks',[])) else 1)" 2>/dev/null \
  || cat <<'HOOKS'
⚠ subagent cleanup hook missing — add to ~/.claude/settings.json "hooks" (the spec item registers it; SALA_SUBAGENT_CLEANUP=off disables it):
   "SubagentStop": [{"matcher": "*", "hooks": [{"type": "command", "command": "~/.local/bin/salamander hook subagent-stop"}]}]
HOOKS
cat <<TXT
✅ salamander → $BIN/salamander  (alias: sala)
   config: $CFG

tmux-resurrect hooks (add to ~/.tmux.conf; keep \`claude\` OUT of @resurrect-processes):
   set -g @resurrect-hook-post-save-all    'salamander revive --save-map'
   set -g @resurrect-hook-post-restore-all 'salamander revive'
   set-hook -g session-created 'run-shell -b "salamander snapshot"'      # event-driven saves: continuum's
   set-hook -g session-closed  'run-shell -b "salamander snapshot"'      # autosave stops when no tmux
   set-hook -g session-renamed 'run-shell -b "salamander snapshot"'      # client is attached
Claude Code SessionStart hook (settings.json): {"type": "command", "command": "salamander snapshot"}

After \`claude update\`:  salamander recycle   (one detached driver, every pane incl. the one you run it from)

Watchdog (the operation queue, the automatic update and recycle, the post-boot report; a master session only if SALA_MASTER names one):
   cp $ROOT/systemd/sala-watch.{service,timer} ~/.config/systemd/user/ && systemctl --user daemon-reload && systemctl --user enable --now sala-watch.timer
TXT

# The web UI (web/README.md): off by default, since it needs uv, ttyd and an HTTPS proxy with a login (docs/web-proxy.md).
. "$ROOT/lib/webunits.sh"
UNITS=$(web_units_dir)
if [ "$WEB" = 1 ]; then
  # an install that ran the units under their old name: migrated (lib/webunits.sh), the new units then run as the old ones did. The
  # migration installs the new units itself and moves the state first, so nothing starts sala-web before its state is in place.
  MIGRATED=0
  if web_legacy_name >/dev/null; then web_migrate "$ROOT" || exit 1; MIGRATED=1; else web_units_install "$ROOT" || exit 1; fi
  web_state_merge || exit 1   # an install migrated by an earlier release, its old state directory still beside the new one
  web_legacy_cmd_link "$ROOT" || exit 1   # the old command's link in web/.venv/bin, while the old name's units exist (also as aliases)
  for dep in uv ttyd caddy; do command -v "$dep" >/dev/null || echo "⚠ missing: $dep ($([ "$dep" = caddy ] && echo 'or any proxy that puts a login in front, docs/web-proxy.md' || echo 'needed by the web UI'))"; done
  if [ "$MIGRATED" = 1 ]; then
    echo
    echo "Web UI units → $UNITS (sala-web.socket, sala-web.service, sala-web-ttyd.service), migrated from the old name (the lines above)."
    echo "   Point the proxy at the new socket paths before the next release drops the old ones (docs/web-proxy.md)."
  else
  cat <<TXT

Web UI units → $UNITS  (sala-web.socket, sala-web.service, sala-web-ttyd.service; ExecStart runs from $ROOT/web)
   cd $ROOT/web && uv sync --frozen
   systemctl --user daemon-reload
   systemctl --user enable --now sala-web.socket sala-web.service sala-web-ttyd.service
   loginctl enable-linger \$USER        # the units keep running after you log out
Both listen on unix sockets only (\$XDG_RUNTIME_DIR/sala-web/sala-web.sock and \$XDG_RUNTIME_DIR/sala-web-ttyd/ttyd.sock) and neither has a login:
put the HTTPS proxy with a login in front of them before anyone but this user can reach them. docs/web-proxy.md has a working example.
TXT
  fi
elif web_legacy_name >/dev/null; then
  # the deploy that brings the renamed units re-runs a plain install.sh: an install with the old units is migrated by it too
  web_migrate "$ROOT" || echo "⚠ the web UI's units were not migrated from their old name; run install.sh --web once the cause is fixed"
else
  web_state_merge || echo "⚠ the old state directory of the web UI was not merged into the new one; run install.sh --web once the cause is fixed"
  echo "Web UI (a browser view of the sessions): install.sh --web, then docs/web-proxy.md for the login in front of it."
fi
