# PROPOSAL, not in force: the session registry's contract with stackshot (phases 3 and 5)

**Status: the sala-to-stackshot half is in force since contract-version 4 (phase 3, interface 19 of `docs/stackshot-contracts.md`), and the stackshot-to-sala half (`projects.json`, phase 5) since contract-version 5 (interface 20, in the shape stackshot published: `front` instead of a `role` of front or back); the rest is a proposal.** Below is the original text. Nothing here was published, `docs/stackshot-contracts.md` is NOT bumped, and phase 1 (this branch) writes only
the local `sessions.json` that nothing reads. Adopting it means bumping `docs/stackshot-contracts.md` to version 2 and telling
the stackshot maintainers first, per that file's bump rule.

## sala to stackshot (phase 3)

Path, per machine: `$SALA_HEARTBEAT_STATE_DIR/<letter>/session-registry.json`, next to `sessions.json` (stackshot's `session_links`),
written by the heartbeat (`publish()`, atomic tmp + replace, `write_if_changed`). A new file, because the existing `sessions.json` is
keyed by live transcript and is a stable contract (stackshot's `session_links` reads it).

```
{ "schema": 1, "machine": "a", "written": "<ISO Z>",
  "sessions": { "<sala session id>": {
      "id": "...", "name": "demo-docs-main", "aliases": ["demo-docs-lead"],
      "project": "<stackshot project id, else the page key until phase 5>", "project_key": "projects/demo-docs",
      "role": "builder", "lane": "subscription-1", "model": "opus", "effort": "medium",
      "pane": "demo-docs-main", "cwd": "...", "state": "live|retired", "created": "<ISO>", "retired_at": null,
      "transcripts": [ {"id": "<claude session id>", "machine": "a", "at": "<ISO>", "why": "add|adopt|spawn|clear|fork|import|record"} ] } } }
```

Retired sessions stay (grow-only), so an old board owner id still resolves. Rule for readers: transcript id to session by scanning
`transcripts[].id`; the last entry is current. The existing `sessions.json` gets one additive field per row, `sid`.

Choices flagged: (a) a separate file versus fields on `sessions.json` (recommended: separate); (b) `aliases` (cheap, lets stored names
in items and pages resolve; recommended); (c) the `role` vocabulary and who owns it (open question 1 below); (d) the tmux session
name stays equal to `name` and is published as `pane` (recommended; decoupling touches the 40 `has-session` sites and makes `tmux ls`
unreadable for the owner). Note that phase 1's local file differs from this in two ways: `why` also takes `add`/`adopt`, and the file
is local and unpublished.

Other sala to stackshot channels stay as they are: the `SALA_SPAWN_REGISTER` hook gets `SALA_SPAWN_SESSION_ID` added (spawn.sh sets
name, project, role, mandate, uuid, lane today); `lanes.tsv` stays name-keyed until stackshot moves to the registry.

## stackshot to sala (phase 5)

What sala needs: `{ "schema": 1, "generated": "<ISO Z>", "projects": { "<project id>": { "id", "key" (project page key), "keeper",
"agents": { "<agent name>": { "role": "front|back|…", "mandate_line": "…" } } } } }`. Mechanism recommended: a file the stackshot
server rewrites atomically, `~/.local/state/stackshot/projects.json`, exactly as it already does for `roles.json`, because spawn only
ever runs on one machine and must not depend on a token or HTTP in the op queue; `client.py get project <id|key>` as the fallback and for
other machines. Freshness: sala treats a file older than 10 minutes as "cannot tell" (exit 1), as it does today. The keeper ask
(`client.py message <key>`) keeps addressing the page key until stackshot says ids are accepted.

## Open questions (for the stackshot maintainers)

1. Role vocabulary: the owner's page says front, builder, ui; spawn takes `--role front|back` and the map has front plus `background:`.
   Which values does the project record carry, and is "which session fills projects/X, builder" answered by sala's registry or by the
   agents map? Recommended: the map says which roles exist, sala says who fills one.
2. Registering an unlisted name: sala prints `ADD-TO-PAGE:` and asks the keeper today. With a record, does sala get a write call, or
   does the block stay a human step?
3. Does `projects.json` carry project id and key, and will `client.py message` accept the id?
4. Will stackshot move owners, roles and inbox holds to the session id on its own schedule, and does the owner's builder
   hooks' name set (it breaks on a rename today) move with it?
5. Old board owners (transcript ids) resolve through `transcripts[]`, so sala keeps retired rows forever: acceptable?
