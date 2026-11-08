"""The roles command's default follows sala's one stackshot knob (SALA_STACKSHOT_DIR): unset it is the same
~/stackshot every other stackshot command in sala uses, a set directory is used, empty means no stackshot (no command, and
the overview says so instead of failing on a bare exec)."""

import asyncio
import sys
import time
import types
from pathlib import Path

from sala_web import config as C
from sala_web import sessions as S


def _tree(root: Path, layout: str) -> Path:
    """A fake stackshot checkout: "new" = the package path, "old" = the root file of a checkout from before the package, "both" =
    the package and the root forwarder beside it, "none" = an empty folder."""
    root.mkdir(parents=True, exist_ok=True)
    if layout in ("new", "both"):
        (root / "stackshot" / "fleet").mkdir(parents=True)
        (root / "stackshot" / "fleet" / "client.py").write_text("")
    if layout in ("old", "both"):
        (root / "client.py").write_text("")
    return root


def test_default_is_the_stackshot_checkout(monkeypatch, tmp_path):
    """Unset, the checkout is ~/stackshot: the package's client when it is there, the root client.py of an older checkout otherwise."""
    monkeypatch.delenv("SALA_WEB_ROLES_CMD", raising=False)
    monkeypatch.delenv("SALA_STACKSHOT_DIR", raising=False)
    monkeypatch.setattr(Path, "home", classmethod(lambda cls: tmp_path))
    assert C.Settings().roles_cmd == ["python3", str(tmp_path / "stackshot" / "stackshot" / "fleet" / "client.py"), "get", "roles"]
    _tree(tmp_path / "stackshot", "old")
    assert C.Settings().roles_cmd == ["python3", str(tmp_path / "stackshot" / "client.py"), "get", "roles"]


def test_the_probe_prefers_the_package_and_falls_back_to_the_root(monkeypatch, tmp_path):
    monkeypatch.delenv("SALA_WEB_ROLES_CMD", raising=False)
    pkg = lambda d: ["python3", str(d / "stackshot" / "fleet" / "client.py"), "get", "roles"]
    root = lambda d: ["python3", str(d / "client.py"), "get", "roles"]
    for layout, want in (("new", pkg), ("old", root), ("both", pkg), ("none", pkg)):
        d = _tree(tmp_path / layout, layout)
        monkeypatch.setenv("SALA_STACKSHOT_DIR", str(d))
        assert C.Settings().roles_cmd == want(d), layout


def test_the_knob_moves_it_and_the_explicit_command_wins(monkeypatch):
    monkeypatch.delenv("SALA_WEB_ROLES_CMD", raising=False)
    monkeypatch.setenv("SALA_STACKSHOT_DIR", "/opt/ss")
    assert C.Settings().roles_cmd == ["python3", "/opt/ss/stackshot/fleet/client.py", "get", "roles"]
    monkeypatch.setenv("SALA_WEB_ROLES_CMD", "echo hi")
    assert C.Settings().roles_cmd == ["echo", "hi"]


def test_empty_knob_means_no_stackshot(monkeypatch, tmp_path):
    monkeypatch.delenv("SALA_WEB_ROLES_CMD", raising=False)
    monkeypatch.setenv("SALA_STACKSHOT_DIR", "")
    st = C.Settings()
    assert st.roles_cmd == []
    cache = S.RolesCache(st)
    assert asyncio.run(cache.get()) == {}
    assert "SALA_STACKSHOT_DIR" in (cache.last_error or "")


def test_the_roles_cache_asks_on_its_first_get_even_just_after_the_machine_booted(monkeypatch):
    """time.monotonic() counts from the machine's boot: a "not asked yet" marker of 0.0 looked like an ask a moment ago for
    the first roles_ttl seconds of the machine's life, and the first get returned no roles without running the command.
    The clock is set to 5 s of uptime here; nothing is slept."""
    monkeypatch.setattr(S, "time", types.SimpleNamespace(monotonic=lambda: 5.0, time=time.time))
    cmd = [sys.executable, "-c", "import json; print(json.dumps({'sessions': {'demo-main': {'role': 'front'}}}))"]
    cache = S.RolesCache(types.SimpleNamespace(roles_cmd=cmd, roles_ttl=30.0))
    assert asyncio.run(cache.get()) == {"demo-main": {"role": "front"}} and cache.last_error is None
