"""A made-up fleet for the Machines tab's tests (test_machines.py, test_machines_ui.py): the files stackshot, the fleet and machine-follow write,
in a temporary folder that is removed when the test ends (and locked while it runs, so an age-based sweep of /tmp leaves it alone). No name
here is a real machine's.

The fleet: alpha-box (letter a, the publisher), beta-box (b; a failed update and a failed setup run), gamma-box (c; no state of any kind),
delta-box (d; its puller is offline), eps-host (letter e AND an ssh host: the two readings merge), zeta-host (an ssh host that answers no
more). machine-follow's list holds eps-host and zeta-host.
"""

from __future__ import annotations

import contextlib
import fcntl
import json
import os
import tempfile
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

ZONE = timezone(timedelta(hours=4))   # Asia/Dubai, the zone conftest pins
FOLLOWED_AT = datetime(2026, 11, 4, 10, 43, 13, tzinfo=ZONE).timestamp()

NAMES = """# os hostname, fleet name, board letter
alpha-os\talpha-box\ta
beta-os\tbeta-box\tb
GAMMA-OS\tgamma-box\tc
delta-os\tdelta-box\td
eps-os\teps-host\te
"""
TOML = {"fleet": {"publisher_letter": "a"}, "machines_panel": {"ssh_hosts": ["eps-host", "zeta-host", "eps-host"]}}
TOML_TEXT = """[fleet]
publisher_letter = "a"

[machines_panel]
ssh_hosts = ["eps-host", "zeta-host", "eps-host"]
"""
FOLLOW = """run_on = "alpha-box"

[machines.eps-host]
follows = ["claude-cli"]
command = ["true"]

[machines.zeta-host]
follows = ["claude-cli"]
command = ["true"]
"""


def versions(zeta_up: bool = False, eps_up: bool = True) -> dict:
    return {"checked": "2026-11-04 10:51 +04", "packages": [
        {"name": "claude code", "installed": "2.1.5", "latest": "2.1.5", "state": "latest",
         "machines": {"a": "2.1.5", "b": "2.1.2", "d": "2.1.5", "e": "2.1.1"},
         "machine_state": {"a": "live", "b": "live", "d": "offline since 2h", "e": "live"}},
        {"name": "gbrain", "installed": "0.5.0", "latest": "0.6.0", "state": "update", "hosts": ["a"]},
    ], "ssh_hosts": [
        {"name": "eps-host", "reachable": eps_up, "checked": "2026-11-04 10:50 +04", "packages": {"claude code": "2.1.4", "gbrain": "0.5.0"}},
        {"name": "zeta-host", "reachable": zeta_up, "checked": "2026-11-04 10:50 +04", "packages": {"claude code": "2.0.0"}},
    ]}


def machine_json(letter: str, fleet: str, **more) -> dict:
    return {"letter": letter, "fleet": fleet, "claude": "2.1.5", "checked": "2026-11-04T06:33:58Z", "master": "secret-session-name",
            "master_session": "11111111-2222-4333-8444-555555555555", "online": {"ok": True, "since": "2026-11-03T19:15:29Z"}, "source": "client", **more}


def update(what: str, ok: bool, at: str, reason: str = "", frm: str = "", to: str = "") -> dict:
    return {"what": what, "ok": ok, "at": at, "reason": reason, "from": frm, "to": to}


@contextlib.contextmanager
def world(now: float | None = None, follow: bool = True, zeta_up: bool = False, eps_up: bool = True):
    """The fleet's files in a temporary folder: yields a namespace with the Settings paths and the stackshot.toml dict. `now` is the time the
    versions file is dated from (4 min before it). The folder is locked while the test runs and removed at the end, whatever the outcome."""
    now = time.time() if now is None else now
    with tempfile.TemporaryDirectory(prefix="sala-machines-test-") as d:
        fd = os.open(d, os.O_RDONLY)
        try:
            fcntl.flock(fd, fcntl.LOCK_SH)
            root = Path(d)
            state, hub, fstate = root / "state", root / "hub" / "ops", root / "follow-state"
            (state / "site").mkdir(parents=True)
            (state / "site" / "versions.json").write_text(json.dumps(versions(zeta_up, eps_up)))
            os.utime(state / "site" / "versions.json", (now - 240, now - 240))   # the reading the tab's footer dates
            for letter, fleet, more in (
                ("a", "alpha-box", {}),
                ("b", "beta-box", {"setup": {"ok": False, "step": 4, "at": "2026-11-04T05:00:00Z", "reason": "the step failed: TOKEN=abc123secret"},
                                   "updates": [update("stackshot checkout", True, "2026-11-04T02:00:00Z", frm="aaa", to="bbb"),
                                               update("claude code", False, "2026-11-04T03:00:00Z", "no space left", "2.1.1", "2.1.2"),
                                               update("claude code", False, "2026-11-04T04:00:00Z", "network down", "2.1.1", "2.1.2"),
                                               update("gbrain", False, "2026-11-04T03:30:00Z", "old failure", "0.4", "0.5"),
                                               update("gbrain", True, "2026-11-04T03:40:00Z", "", "0.4", "0.5")]}),
                ("d", "delta-box", {}),
            ):
                (state / "clients" / "fleet" / letter).mkdir(parents=True)
                (state / "clients" / "fleet" / letter / "machine.json").write_text(json.dumps(machine_json(letter, fleet, **more)))
            hub.mkdir(parents=True)
            (hub / "fleet-names.tsv").write_text(NAMES)
            (hub / "claude" / "machine-follow").mkdir(parents=True)
            (hub / "claude" / "machine-follow" / "machines.toml").write_text(FOLLOW)
            fstate.mkdir()
            (root / "config" / "stackshot").mkdir(parents=True)                  # XDG_CONFIG_HOME for a test that runs the whole app: stackshot's settings file
            (root / "config" / "stackshot" / "stackshot.toml").write_text(TOML_TEXT)
            if follow:
                (fstate / "eps-host.json").write_text(json.dumps({"machine": "eps-host", "at": "x", "at_epoch": int(FOLLOWED_AT)}))
            yield type("World", (), {"root": root, "state": state, "names": hub / "fleet-names.tsv", "follow": hub / "claude" / "machine-follow" / "machines.toml",
                                     "fstate": fstate, "toml": TOML, "now": now, "config": root / "config"})
        finally:
            os.close(fd)


def settings(w, **over):
    """A Settings that reads this world and nothing else."""
    from sala_web.config import Settings
    s = Settings(stackshot_state=w.state, fleet_names_file=w.names, follow_machines_file=w.follow, follow_state_dir=w.fstate)
    for k, v in over.items():
        setattr(s, k, v)
    return s
