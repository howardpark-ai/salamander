# Running without stackshot

sala runs without the stackshot board; this lists the one place that needs it and every integration that stays optional.

sala installs and runs without stackshot (the owner's board). Every integration is a knob that is unset by default, a file
that is written whether or not anyone reads it, or a call that fails open with one log line: the heartbeat store, the
message marker, the inbox hold, the post-recycle hook, recycle-wanted, the spawn keeper ask, the release report, and
sala-web's board items and roles. With stackshot on the box, two lines in the config turn the board half on
(`SALA_POST_RECYCLE_CMD`, `SALA_RECYCLE_WANTED_CMD`, `config.example`). Where stackshot's checkout is comes from one knob,
`SALA_STACKSHOT_DIR` (unset: `~/stackshot`, as every default was before; set empty on a box with no stackshot, and each default
command that names `pages.py` or `client.py` is empty at once; the explicit knobs still win; `config.example`). Inside that folder the
programs are at stackshot's package paths (`stackshot/fleet/client.py`, `stackshot/projects/pages.py`; the update hook's example is
`stackshot/web/publish.py bump`, the mockup pass's `stackshot/tools/open_item_text.py --links`); a checkout from before the package keeps them
in its root (`client.py`, `pages.py`), and sala's defaults use that path while it is the only one there (`lib/stackshot-path.sh`). What needs
stackshot today: `spawn --project` is **the one command that needs stackshot and a local mirror of the pages**: its page and agents-map checks
read stackshot's project record, then `pages.py` (with the local mirror of the pages behind it) when the record cannot answer, and the spawn is
refused when neither can. That refusal is by design and stays fail-closed (the web form and the queue run it unattended, and a
session made before its agents line exists reads no mandate); `SALA_AGENT_CHECK=off` is the only bypass, for every spawn. There is
no abstraction over the check: one is built only when a box without stackshot has to make project spawns. The other is `sala reboot` on a box whose `SALA_REBOOT_HOOKS` names stackshot's hooks.

**Contracts.** Every interface between the two, in both directions, is listed in
[`docs/stackshot-contracts.md`](stackshot-contracts.md) (**contract-version 11**, Mon Oct 26th 2026): the path or
command, its exact shape, who owns each side, what happens when the other side is missing, and the suite that guards it.
A change to any of them bumps that version.
