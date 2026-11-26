#!/usr/bin/env bash
# `sala reauth` (lib/reauth.sh) against a fake `claude` on PATH that answers `mcp login` and `mcp get` as the 2.1.294
# CLI does for a claude.ai connector. --done queues nothing itself (the queue takes the owner's words verbatim), so the
# checks are what keeps it from pointing at a recycle for nothing: --done refuses while the connector needs
# authentication, has no status, failed to connect or fetched no tools; connected, it prints the exact
# `sala op recycle --force` line, queues nothing and exits 0, --dry-run or not and with --from or without. Also: a
# token-looking value in a failed login's output is masked.
# No real connector or session is touched.
set -u
unset TMUX TMUX_PANE
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
export HOME=$(mktemp -d); mkdir -p "$HOME/bin"; export SALA_CONFIG=/dev/null PATH="$HOME/bin:$PATH" TMUX_TMPDIR="$HOME"   # a private tmux socket dir, never the fleet's server
trap 'rm -rf "$HOME"' EXIT
SALA="$ROOT/bin/salamander"
cat > "$HOME/bin/claude" <<'FAKE'
#!/bin/bash
case "$1 $2" in
    "mcp login") echo "error: callback?code=SECRETVALUE123&state=x token=abc123"; exit 1 ;;   # a failed login, token-looking values in it
    "mcp get") case "${FAKE_STATUS:-ok}" in
        ok) printf '%s:\n  Scope: claude.ai config\n  Status: ✔ Connected\n' "$3" ;;
        auth) printf '%s:\n  Scope: claude.ai config\n  Status: ! Needs authentication\n' "$3" ;;
        failed) printf '%s:\n  Scope: claude.ai config\n  Status: ✘ Failed to connect\n' "$3" ;;
        partial) printf '%s:\n  Scope: claude.ai config\n  Status: ! Connected · tools fetch failed\n' "$3" ;;
        missing) echo "No MCP server named \"$3\"."; exit 1 ;;
        esac ;;
esac
FAKE
chmod +x "$HOME/bin/claude"
run() { out=$("$SALA" reauth "$@" 2>&1); rc=$?; }

echo "== the login"
run Stackshot
[ "$rc" = 1 ] && [[ $out != *SECRETVALUE123* ]] && [[ $out != *abc123* ]] && ok "a token-looking value in the CLI's output is masked" || bad "leaky: $out"

echo "== --done"
FAKE_STATUS=auth run Stackshot --done --dry-run
[ "$rc" = 1 ] && [[ $out == *"still needs authentication"* ]] && [[ $out != *"would run"* ]] && ok "needs authentication: nothing queued, exit 1" || bad "auth: rc=$rc $out"
FAKE_STATUS=failed run Stackshot --done --dry-run
[ "$rc" = 1 ] && [[ $out == *"nothing was queued"* ]] && ok "failed to connect: nothing queued" || bad "failed: rc=$rc $out"
FAKE_STATUS=partial run Stackshot --done --dry-run
[ "$rc" = 1 ] && [[ $out == *"nothing was queued"* ]] && ok "connected but its tools fetch failed: nothing queued" || bad "partial: rc=$rc $out"
FAKE_STATUS=missing run Nope --done --dry-run
[ "$rc" = 1 ] && [[ $out == *"no status"* ]] && ok "no such connector: nothing queued" || bad "missing --done: rc=$rc $out"
mkdir -p "$HOME/.local/state/salamander/ops"
run Stackshot --done --from example-x
[ "$rc" = 0 ] && [[ $out == *'sala op recycle --force --from example-x --words "<Rowan'"'"'s words>"'* ]] && [[ $out != *"handing"* ]] \
    && [ -z "$(ls "$HOME/.local/state/salamander/ops" 2>/dev/null)" ] && ok "connected: the exact sala op recycle --force line, nothing queued, exit 0" || bad "connected: rc=$rc $out"

run Stackshot --done --dry-run
[ "$rc" = 0 ] && [[ $out == *'sala op recycle --force --from <you> --words'* ]] && [ -z "$(ls "$HOME/.local/state/salamander/ops" 2>/dev/null)" ] && ok "--dry-run, no --from: the same line with <you>, nothing queued" || bad "dry-run: rc=$rc $out"
run --help
[ "$rc" = 0 ] && [[ $out == *"salamander reauth NAME --done"* ]] && [[ $out == *"queues the forced recycle"* ]] && [[ $out != *master* ]] && [[ $out != *cue* ]] && ok "reauth --help: the queue line, no retired verb or cue" || bad "help: rc=$rc $out"

[ "$fail" = 0 ] && echo "reauth: pass" || echo "reauth: FAIL"
exit $fail
