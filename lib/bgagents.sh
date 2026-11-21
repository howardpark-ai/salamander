# lib/bgagents.sh — `sala bg-agents`: give a project a background (engineer) agent when stackshot says it wants one (docs/bg-agents.md). Sourced by bin/salamander;
# the work is lib/bgagents.py (standard library, no model call). The timer unit is made by `sala job add` (the docs page says how); nothing here installs one.
bgagents_usage() {
    cat <<'USAGE'
usage: sala bg-agents [--dry-run]
       sala bg-agents --status
       sala bg-agents --reset <project key> [--dry-run]

  A run (off unless SALA_BGAGENTS=on in the config): reads stackshot's want list (`client.py background-wanted`, one line `<project key> <name prefix>
          <front agent>` a project), takes AT MOST ONE project that is not in back-off or given up, checks the load (1-minute average under
          SALA_BGAGENTS_MAX_LOAD, 10; at or above it the run skips and takes nothing from the ledger), lists the agent <name prefix>-engineer on the project
          (`client.py post project-agent … --role engineer --back`, the label SALA_BGAGENTS_SENDER, sala-web) and starts its pane
          (`sala spawn <name> --project <key> --role back --mandate <line>`), then checks it is live. One line a decision. Exit 0 = the run finished (a skip and
          a failed project too), 1 = a retire is needed (`retire needed: <name>`: an agent this job listed could not be started and no path takes it off
          without the owner's words) or a board item is needed and could not be raised (`board item needed: <project>`, below), 2 = usage or a bad setting.
  --dry-run  the whole decision; nothing is posted, started or written (the want list and the load are read).
  --status   the ledger (<state>/bgagents.json), one line a project: attempts, failures, next try, state. Read-only; works with the switch off.
  --reset    clears one project's ledger entry (attempts, failures, back-off, given up, retire needed, the board item, the last outcome) so the next run tries it afresh; the
          agent's entry on the project is left as it is (the next run sees it already listed and goes to the start). A ledger edit, not a run: it works with the switch off,
          writes atomically, prints one line, and refuses a key with no entry (exit 1). With --dry-run it says what it would clear and writes nothing. It is what a session runs
          when the owner answers "Keep trying later" on the board item below; the owner never runs it.

  A project it cannot start is never left silent: when one reaches the attempt cap ("given up") or an agent this job listed did not start (retire needed), the
  job raises ONE board item for the owner (`client.py post question`: what happened in plain words, and three options), once per project; the ledger keeps
  it (--status: "given up (board item raised)" or "(board item not raised yet)"). Once raised, the job makes no start attempt for that project until a session
  resets it (--reset). The raise comes after the run's start attempt, at most one a run, with its own timeout (SALA_BGAGENTS_RAISE_TIMEOUT, 30 s) and without the
  ledger lock held. A project whose agent session is live is not raised for ("agent running, want list stale"). A raise that fails says `board item needed:
  <project>`, exits 1 and is tried again at the next run. It is no attempt and no failure of the project. --dry-run raises nothing.

  Ledger and back-off: after a failure the project waits SALA_BGAGENTS_COOLDOWN seconds (600), doubled for every further failure up to
  SALA_BGAGENTS_COOLDOWN_MAX (86400); at SALA_BGAGENTS_MAX_ATTEMPTS (5) attempts it is left alone ("given up"). An entry is cleared only after its project
  has been off the want list for the cooldown. Settings are in config.example (all commented, default off); docs/bg-agents.md has the rules.
USAGE
}
case "${1:-}" in
    -h|--help|help) bgagents_usage; exit 0 ;;
    ''|--dry-run|--status|--reset) ;;
    *) echo "salamander bg-agents: unknown argument '$1'" >&2; bgagents_usage >&2; exit 2 ;;
esac
# the config file is sourced (common.sh), so a `NAME=value` line there is a shell variable, not part of the environment lib/bgagents.py reads: export the
# settings it takes (a no-op for one that is unset; the systemd service has only PATH in its environment, so the config is its only source)
export SALA_BGAGENTS SALA_BGAGENTS_COOLDOWN SALA_BGAGENTS_COOLDOWN_MAX SALA_BGAGENTS_MAX_ATTEMPTS SALA_BGAGENTS_MAX_LOAD SALA_BGAGENTS_MANDATE SALA_BGAGENTS_SENDER \
       SALA_BGAGENTS_LEDGER SALA_BGAGENTS_LOADAVG SALA_BGAGENTS_RECORD_GRACE SALA_BGAGENTS_ALIVE_WAIT SALA_BGAGENTS_POST_TIMEOUT SALA_BGAGENTS_SPAWN_TIMEOUT SALA_BGAGENTS_RAISE_TIMEOUT \
       SALA_BGAGENTS_SUBJECT_PREFIX SALA_DEFAULT_SCOPE SALA_SCOPES \
       SALA_PROJECT_RECORD SALA_PROJECT_RECORD_MAX_AGE SALA_TZ SALA_OWNER_NAME SALA_STATE_DIR
# the six commands: a setting wins (also an empty one: no client), else the stackshot client / this sala (the suites stub them)
if [ -z "${SALA_BGAGENTS_LIST_CMD+x}" ] || [ -z "${SALA_BGAGENTS_POST_CMD+x}" ] || [ -z "${SALA_BGAGENTS_ASK_CMD+x}" ] || [ -z "${SALA_BGAGENTS_PREFIXES_CMD+x}" ]; then
    _bg_client=$(stackshot_client 2>/dev/null) || _bg_client=""
    [ -n "${SALA_BGAGENTS_LIST_CMD+x}" ] || SALA_BGAGENTS_LIST_CMD="${_bg_client:+python3 $_bg_client background-wanted}"
    [ -n "${SALA_BGAGENTS_POST_CMD+x}" ] || SALA_BGAGENTS_POST_CMD="${_bg_client:+python3 $_bg_client post project-agent}"
    [ -n "${SALA_BGAGENTS_ASK_CMD+x}" ] || SALA_BGAGENTS_ASK_CMD="${_bg_client:+python3 $_bg_client post question}"
    [ -n "${SALA_BGAGENTS_PREFIXES_CMD+x}" ] || SALA_BGAGENTS_PREFIXES_CMD="${_bg_client:+python3 $_bg_client get config}"
    unset _bg_client
fi
: "${SALA_BGAGENTS_SPAWN_CMD=$SALA_BIN spawn}"
: "${SALA_BGAGENTS_ALIVE_CMD=$SALA_BIN sessions resolve}"
export SALA_BGAGENTS_LIST_CMD SALA_BGAGENTS_POST_CMD SALA_BGAGENTS_ASK_CMD SALA_BGAGENTS_PREFIXES_CMD SALA_BGAGENTS_SPAWN_CMD SALA_BGAGENTS_ALIVE_CMD
exec python3 -I -S "$SALA_ROOT/lib/bgagents.py" "$@"
