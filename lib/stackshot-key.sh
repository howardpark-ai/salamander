# lib/stackshot-key.sh — `sala stackshot-key`: sala's own key for stackshot, and the pass it trades for (docs/stackshot-contracts.md, "A caller's own key").
# Sourced by bin/salamander; the work is lib/stackshot_key.py (standard library and the `cryptography` package). Prints no secret.
stackshot_key_usage() {
    cat <<'USAGE'
usage: sala stackshot-key init
       sala stackshot-key enroll
       sala stackshot-key status

  init    makes sala's Ed25519 key for stackshot if there is none (idempotent) and prints its short fingerprint (the first 16 characters). The private half is kept
          in $XDG_STATE_HOME/salamander/stackshot-key/key (folder 700, file 600), made once and never overwritten, printed, logged or put on a command line.
  enroll  init, then asks stackshot to trust the key's public half (once per machine). Prints only: the state (pending | approved), the short fingerprint, the board
          item the server answers and what happens next: the owner approves it on that item. Run it again at any time: the same key answers its state again.
  status  key present or not, its short fingerprint and the server's state for it, from a signed claim: approved (a pass came back), pending or unknown. No secret.

  Once the key is approved, the New session form's calls (spawn's registration of a project agent, rename, retire, forget-row, bg-agents and sala-web's form) go
  with a pass the key trades for (valid 10 minutes, reused until 60 s before it ends) instead of the machine token. It never blocks: with no key, a key still
  waiting, a server that is not reached or one that says no, the call runs with the machine token as before, and one line per five minutes in
  $SALA_LOG_DIR/salamander-stackshot-key.log says why no pass was used. SALA_STACKSHOT_PASS=off skips the pass step. Everything else sala asks of stackshot keeps the machine token.
USAGE
}
case "${1:-}" in
    ''|-h|--help|help) stackshot_key_usage; [ -n "${1:-}" ] || exit 2; exit 0 ;;
    init|enroll|status) ;;
    *) echo "salamander stackshot-key: unknown argument '$1'" >&2; stackshot_key_usage >&2; exit 2 ;;
esac
[ $# = 1 ] || { echo "salamander stackshot-key: $1 takes no argument" >&2; stackshot_key_usage >&2; exit 2; }
export SALA_STATE_DIR SALA_LOG_DIR
exec python3 "$SALA_ROOT/lib/stackshot_key.py" "$1"
