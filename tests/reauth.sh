#!/usr/bin/env bash
# `sala reauth` (lib/reauth.sh) against a fake `claude` on PATH that answers `mcp login` and `mcp get` as the 2.1.294
# CLI does for a claude.ai connector. --done hands a forced fleet recycle to the master, so the checks are what keeps it
# from cueing one for nothing (the link and usage wording checks were dropped): --done refuses to cue while the
# connector needs authentication, has no status, failed to connect or fetched no tools; --done --dry-run prints the exact
# cue the master acts on (with --from); --done for real hands the words to `sala cue` (SALA_CUE_TARGET names a master that
# is not live in the sandbox, so cue's own "not live" answer proves the hand-over); with no master, --done prints the exact
# `sala op recycle --force` line, queues nothing and exits 0. Also: a token-looking value in a failed login's output is masked.
# No real connector or session is touched.
set -u
unset TMUX TMUX_PANE
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
export HOME=$(mktemp -d); mkdir -p "$HOME/bin"; export SALA_CONFIG=/dev/null PATH="$HOME/bin:$PATH" TMUX_TMPDIR="$HOME"   # a private tmux socket dir: the cue looks up its master there, never on the fleet's server
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
CUE='recycle claude: the Stackshot connector was re-authorized, every pane must reload its connectors'
FAKE_STATUS=auth run Stackshot --done --dry-run
[ "$rc" = 1 ] && [[ $out == *"still needs authentication"* ]] && [[ $out != *"would run"* ]] && ok "needs authentication: nothing cued, exit 1" || bad "auth: rc=$rc $out"
FAKE_STATUS=failed run Stackshot --done --dry-run
[ "$rc" = 1 ] && [[ $out == *"nothing was cued"* ]] && ok "failed to connect: nothing cued" || bad "failed: rc=$rc $out"
FAKE_STATUS=partial run Stackshot --done --dry-run
[ "$rc" = 1 ] && [[ $out == *"nothing was cued"* ]] && ok "connected but its tools fetch failed: nothing cued" || bad "partial: rc=$rc $out"
FAKE_STATUS=missing run Nope --done --dry-run
[ "$rc" = 1 ] && [[ $out == *"no status"* ]] && ok "no such connector: nothing cued" || bad "missing --done: rc=$rc $out"
SALA_CUE_TARGET=sala-test-nomaster-$$ run Stackshot --done --dry-run --from example-x
[ "$rc" = 0 ] && [[ $out == *"[dry-run] would run: sala cue --from example-x \"$CUE\""* ]] && ok "connected, a master, --dry-run: the exact cue, with --from" || bad "dry-run: rc=$rc $out"
SALA_CUE_TARGET=sala-test-nomaster-$$ run Stackshot --done --from example-x
[ "$rc" != 0 ] && [[ $out == *"handing the forced recycle to the master"* ]] && [[ $out != *"sala op recycle"* ]] \
    && ok "a master, for real: handed to sala cue (which answers: not live in the sandbox)" || bad "real: rc=$rc $out"
mkdir -p "$HOME/.local/state/salamander/ops"
run Stackshot --done --from example-x
[ "$rc" = 0 ] && [[ $out == *'sala op recycle --force --from example-x --words "<Rowan'"'"'s words>"'* ]] && [[ $out != *"handing the forced recycle to the master"* ]] \
    && [ -z "$(ls "$HOME/.local/state/salamander/ops" 2>/dev/null)" ] && ok "no master: the exact sala op recycle --force line, nothing queued, exit 0" || bad "no master: rc=$rc $out"

[ "$fail" = 0 ] && echo "reauth: pass" || echo "reauth: FAIL"
exit $fail
