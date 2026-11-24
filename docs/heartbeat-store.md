# Heartbeat store

What the heartbeat writes, where it keeps it, and how another tool can read it.

`heartbeat` is the only verb that writes outside the machine, and one box writes the whole store. The live store is a
local directory (`SALA_HEARTBEAT_STATE_DIR`) the consumer reads; git (`SALA_HEARTBEAT_REPO`) is optional (`SALA_HEARTBEAT_GIT=off` keeps the store out of it; the retired `master` value is read as `full`). The writer: the driving box
(`SALA_FLEET_HOSTS` set) sweeps the others over ssh — version and live sessions (a registry file whose pid runs) — so
they run nothing for it; a box that does not answer ssh is offline and keeps its last files. It knows nothing about the consumer: the store is a
directory in a git checkout (`SALA_HEARTBEAT_REPO`, `SALA_HEARTBEAT_DIR`), the machine's subdirectory is a letter from
`SALA_FLEET_NAMES` (a TSV of `hostname → fleet name → letter`) or `SALA_HEARTBEAT_LETTER`, and the two files follow a
fixed contract: `machine.json` = `{letter, fleet, claude, checked, master, master_session, fleet_ssh}` (`master` and `master_session` are always written as empty strings: the keys stay for the contract, nothing reads them; `fleet_ssh` on the driving box:
`{fleet name: {letter, ok, since}}`); `sessions.json` = one entry per live pane keyed by
its transcript UUID, `{name, url, seen, machine}` (a sleeping session, whose claude ended on purpose, has a row too, with one more key, `"sleeping": "<ISO-Z>"`, its marker's time; docs/subcommands.md, *Sleeping sessions*), where `url` is the session's link: on the writer's own rows the sala-web link
`SALA_SESSION_URL` gives (Tue Oct 13th 2026), bridged or not; on a swept box's rows the Remote Control address, empty
while the bridge is down. Session
identity is the UUID on purpose — it survives resumes, renames and bridge breaks, so a consumer that stores the UUID as
an owner resolves the current name and URL at render time. `checked` and `seen` are the times of the last change, not
of the last run: a run that finds nothing new leaves the files, and the repo, untouched.

Two more files are written to the live store only, for this box's own letter, never into git: `session-registry.json` (docs/session-registry.md) and `agent-state.json`. The second says, for each
live or sleeping agent of the session registry, whether it is busy, idle or unknown (`state`, since when, `why`), what its pane is doing (`pane`: turn, idle, shell, sleeping) and which subagents run (`subagents`, from
stackshot's own `running()`, imported from its checkout: `SALA_STACKSHOT_CHECKOUT`). Unlike `machine.json` and `sessions.json` it is rewritten on every run (`written` moves), and it is then posted to stackshot
(`SALA_AGENT_STATE_POST_CMD`, `SALA_AGENT_STATE_TIMEOUT`; the default command is stackshot's client with the machine token, not a pass, which stackshot accepts only on the New session form's calls; a failure is one log line per five minutes, never a failed heartbeat). `SALA_AGENT_STATE=off` turns both off. The shape, the staleness rule a reader applies and the
size limit are docs/stackshot-contracts.md, interface 38.
