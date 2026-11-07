# lib/follow.sh — `salamander follow`: the resident watcher (lib/follow.py; Linux inotify). Run by sala-follow.service.
[ "$(uname -s)" = Linux ] || die "follow needs Linux inotify; elsewhere \`salamander watch\` is the backstop"
export SALA_BIN SALA_REG_DIR SALA_LOG_DIR SALA_FOLLOW_QUIET SALA_FOLLOW_MAX SALA_FOLLOW_TIMEOUT
exec python3 "$SALA_ROOT/lib/follow.py"
