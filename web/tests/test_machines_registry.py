"""The Machines tab and sala's machine registry (lib/machines.py `machine_list`): the tab takes WHICH machines exist, with their names and letters, from the
registry, and shows exactly the cards it showed before the registry existed. Made-up files in temporary folders (machines_world.py, prefix sala-machines-test-,
and one more here, sc1565-); no real machine is named, nothing is written to a machine file.

What a wrong answer costs: a card that appears or goes missing when the registry is read (the owner sees a machine that is not there, or none for one that is),
a retired machine's letter turned into a card, a machine only the follow, ssh or candidate files name made a card before the versions move to the registry too,
or a tab that stops working when the registry cannot be loaded.
"""

from __future__ import annotations

import contextlib
import fcntl
import importlib.util
import os
import tempfile
from pathlib import Path

from machines_world import TOML, settings, world
from sala_web import machines as M

LIB = Path(__file__).resolve().parents[2] / "lib" / "machines.py"


def registry():
    spec = importlib.util.spec_from_file_location("machines_registry_under_test", LIB)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@contextlib.contextmanager
def scratch():
    """A temporary folder, locked while the test runs and removed at the end, whatever the outcome."""
    with tempfile.TemporaryDirectory(prefix="sc1565-") as d:
        fd = os.open(d, os.O_RDONLY)
        try:
            fcntl.flock(fd, fcntl.LOCK_SH)
            yield Path(d)
        finally:
            os.close(fd)


def names(d: dict) -> list[str]:
    return [c["name"] for c in d["machines"]["cards"]]


def test_the_cards_are_the_registrys_machines_with_a_letter_and_the_listed_ssh_hosts_in_the_order_they_had():
    with world() as w:
        s = settings(w)
        listed = registry().machine_list(w.names, w.follow)
        d = M.collect(s, toml=TOML, now=w.now)
    assert [m["name"] for m in listed if m["letter"]] == ["alpha-box", "beta-box", "gamma-box", "delta-box", "eps-host"]
    # the same cards, in the same order, as before the registry: the publisher, the fleet by letter, then the ssh hosts nobody has a letter for
    assert names(d) == ["alpha-box", "beta-box", "gamma-box", "delta-box", "eps-host", "zeta-host"]
    # every machine the registry gives a letter is a card of the tab (none dropped); one the registry lists with none (zeta-host: the follow list names it) is a card only because
    # the settings list it as an ssh host, as before
    assert {m["name"] for m in listed if m["letter"]} <= set(names(d))


def test_the_collected_machines_equal_the_registrys_names_for_the_fleet_names_file():
    with scratch() as t:
        hub = t / "hub"
        (hub / "claude" / "tailnet-route").mkdir(parents=True)
        (hub / "ssh").mkdir()
        (hub / "fleet-names.tsv").write_text("# os hostname, fleet name, letter\none-os\texample-one\ta\ntwo-os\texample-two\tb\nthree-os\texample-three\tt\n")
        (hub / "claude" / "tailnet-route" / "candidates.conf").write_text("host example-one 192.0.2.1 2001:db8::1\nhost example-two 192.0.2.2 2001:db8::2\n")
        (hub / "ssh" / "fleet.conf").write_text("Host example-one\n  HostName one.example.invalid\nHost example-three\n  HostName three.example.invalid\n")
        from sala_web.config import Settings
        s = Settings(stackshot_state=t / "no-state", fleet_names_file=hub / "fleet-names.tsv", follow_machines_file=None, follow_state_dir=t / "no-follow")
        # the tab's machines, which need no versions file for their identity
        listed = M.machine_list(s)
        order = M.machines_order(M.fleet_names(s), [], "a")
    assert [m["name"] for m in listed] == ["example-one", "example-two", "example-three"]
    assert [n for n, _ in order] == [m["name"] for m in listed]
    assert [l for _, l in order] == ["a", "b", "t"]


def test_a_retired_letter_is_no_card_of_its_own_and_a_machine_with_no_letter_is_not_made_one():
    with scratch() as t:
        (t / "fleet-names.tsv").write_text("one-os\texample-one\ta\n# e = example-gone, retired (its letter stays reserved)\n")
        (t / "claude" / "tailnet-route").mkdir(parents=True)
        (t / "claude" / "tailnet-route" / "candidates.conf").write_text("host example-one 192.0.2.1 2001:db8::1\nhost example-nolabel 192.0.2.9 2001:db8::9\n")
        from sala_web.config import Settings
        s = Settings(stackshot_state=t / "no-state", fleet_names_file=t / "fleet-names.tsv", follow_machines_file=None, follow_state_dir=t / "no-follow")
        listed = {m["name"]: m for m in M.machine_list(s)}
        letters = M.fleet_names(s)
    assert listed["example-gone"]["retired"] is True and listed["example-gone"]["letter"] == "e"
    assert "example-nolabel" in listed and listed["example-nolabel"]["letter"] == ""
    assert letters == {"a": "example-one"}   # the retired letter and the machine with no letter are no machine of the fleet's panel


def test_a_machine_that_only_the_fleet_state_names_is_still_a_card_as_before():
    with world() as w:
        d = M.collect(settings(w), toml=TOML, now=w.now)
        # the fleet state of a letter the names file does not list (a machine whose box is not in the registry's files) keeps its card
        (w.state / "clients" / "fleet" / "f").mkdir()
        (w.state / "clients" / "fleet" / "f" / "machine.json").write_text('{"letter": "f", "fleet": "fleet-only-box"}')
        d2 = M.collect(settings(w), toml=TOML, now=w.now)
    assert "fleet-only-box" not in names(d) and "fleet-only-box" in names(d2)
    assert names(d2) == names(d)[:5] + ["fleet-only-box"] + names(d)[5:]


def test_the_tab_still_answers_when_the_registry_cannot_be_loaded(monkeypatch):
    with world() as w:
        before = M.collect(settings(w), toml=TOML, now=w.now)
        monkeypatch.setattr(M, "_machines_lib", lambda: None)
        d = M.collect(settings(w), toml=TOML, now=w.now)
    assert d["machines"]["ok"] is True
    # without the registry the names file is not read at all: the cards are the fleet state's letters and the ssh hosts, never a 500
    assert set(names(d)) <= set(names(before)) and "eps-host" in names(d)


def test_the_registry_the_tab_reads_is_the_one_the_command_line_prints():
    with world() as w:
        s = settings(w)
        mine = M.machine_list(s)
        theirs = registry().machine_list(w.names, w.follow)
    assert mine == theirs and [m["name"] for m in mine]
