"""The zone and the Shell drawer's names, as the page is told them (GET /api/config), and where the zone comes from.

No zone is built in: SALA_TZ (an IANA name) set gives that zone and its own label; unset, empty or a name that is no zone gives this
machine's local time and the page shows the viewer's. sala-web has no sala environment, so SALA_TZ and SALA_SHELL_SESSION are also read
from the line in sala's config file. conftest.py pins SALA_CONFIG at a file that is not there, SALA_TZ at Asia/Dubai and leaves
SALA_SHELL_SESSION unset.
"""

import json
import shutil
import socket
import subprocess
from datetime import datetime, timezone
from pathlib import Path

import pytest
from starlette.testclient import TestClient

from sala_web import tz as TZ
from sala_web.app import create_app
from sala_web.config import Settings, sala_setting

HOST = socket.gethostname().split(".")[0]
WINTER = datetime(2026, 1, 15, 12, 0, tzinfo=timezone.utc)
SUMMER = datetime(2026, 7, 15, 12, 0, tzinfo=timezone.utc)


def client_for(tmp_path) -> TestClient:
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True, exist_ok=True)
    (claude / "projects").mkdir(exist_ok=True)
    s = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude,
                 tmux_socket_name="salaweb-pytest-unused", roles_cmd=["false"])
    return TestClient(create_app(s))


def config_of(tmp_path) -> dict:
    return client_for(tmp_path).get("/api/config").json()


def test_the_page_is_told_the_zone_the_session_name_and_the_machine(tmp_path):
    c = config_of(tmp_path)   # conftest: SALA_TZ=Asia/Dubai, no SALA_SHELL_SESSION
    assert c["timezone"] == "Asia/Dubai" and c["tzLabel"] == "+04" and c["tzOffsetMin"] == 240
    assert c["shellSession"] == "sala-shell" and c["host"] == HOST


def test_another_zone_is_told_with_its_own_label_and_its_summer_offset(tmp_path, monkeypatch):
    monkeypatch.setenv("SALA_TZ", "Europe/Berlin")
    c = config_of(tmp_path)
    assert c["timezone"] == "Europe/Berlin" and c["tzLabel"] in ("CET", "CEST") and c["tzOffsetMin"] in (60, 120)
    assert TZ.label(WINTER) == "CET" and TZ.offset_min(WINTER) == 60
    assert TZ.label(SUMMER) == "CEST" and TZ.offset_min(SUMMER) == 120


@pytest.mark.parametrize("value", ["", "Not/AZone"])
def test_no_zone_set_or_one_that_is_no_zone_is_the_machines_local_time(tmp_path, monkeypatch, value):
    monkeypatch.delenv("SALA_TZ")
    if value:
        monkeypatch.setenv("SALA_TZ", value)
    monkeypatch.setenv("TZ", "America/New_York")
    c = config_of(tmp_path)
    assert c["timezone"] == "" and c["tzLabel"] in ("EST", "EDT") and c["tzOffsetMin"] in (-300, -240)   # "" tells the page to use the viewer's
    assert TZ.label(WINTER) == "EST" and TZ.label(SUMMER) == "EDT"
    assert TZ.convert(WINTER).strftime("%H:%M") == "07:00"
    assert "+04" not in str(c)


def test_a_naive_time_is_taken_as_utc(monkeypatch):
    assert TZ.convert(datetime(2026, 1, 15, 12, 0)).strftime("%H:%M %Z") == "16:00 +04"   # conftest's Asia/Dubai
    monkeypatch.setenv("SALA_TZ", "Etc/UTC")
    assert TZ.convert(datetime(2026, 1, 15, 12, 0)).strftime("%H:%M %Z") == "12:00 UTC"


def test_the_zone_and_the_session_name_are_read_from_sala_config_file(tmp_path, monkeypatch):
    cfg = tmp_path / "config"
    cfg.write_text("# a note\nSALA_TZ='Asia/Kolkata'   # the viewer is here\nexport SALA_SHELL_SESSION=my-console\n")
    monkeypatch.setenv("SALA_CONFIG", str(cfg))
    monkeypatch.delenv("SALA_TZ")
    assert sala_setting("SALA_SHELL_SESSION", "sala-shell") == "my-console"
    assert TZ.setting() == "Asia/Kolkata" and TZ.label() == "IST" and TZ.offset_min() == 330
    assert config_of(tmp_path)["timezone"] == "Asia/Kolkata"
    monkeypatch.setenv("SALA_TZ", "Europe/Berlin")   # the environment wins over the file, as for any sala setting
    assert TZ.setting() == "Europe/Berlin"


def test_a_missing_or_empty_config_file_gives_the_defaults(tmp_path, monkeypatch):
    monkeypatch.delenv("SALA_TZ")
    assert TZ.setting() == "" and sala_setting("SALA_SHELL_SESSION", "sala-shell") == "sala-shell"   # conftest: the config file is not there
    empty = tmp_path / "config"
    empty.write_text("")
    monkeypatch.setenv("SALA_CONFIG", str(empty))
    assert TZ.setting() == "" and sala_setting("SALA_SHELL_SESSION", "sala-shell") == "sala-shell"


def test_the_config_file_is_parsed_again_only_when_it_changed(tmp_path, monkeypatch):
    cfg = tmp_path / "config"
    cfg.write_text("SALA_TZ=Asia/Kolkata\n")
    monkeypatch.setenv("SALA_CONFIG", str(cfg))
    monkeypatch.delenv("SALA_TZ")
    calls = []
    real = TZ.sala_setting
    monkeypatch.setattr(TZ, "sala_setting", lambda *a, **k: (calls.append(a), real(*a, **k))[1])
    assert TZ.setting() == "Asia/Kolkata" and TZ.setting() == "Asia/Kolkata" and TZ.setting() == "Asia/Kolkata"
    assert len(calls) == 1   # three asks, one parse
    cfg.write_text("SALA_TZ=Europe/Berlin\n")   # a changed file (new size and mtime) is read at the next call, no restart
    assert TZ.setting() == "Europe/Berlin" and len(calls) == 2
    monkeypatch.setenv("SALA_TZ", "Etc/UTC")   # the environment's value is part of the key
    assert TZ.setting() == "Etc/UTC" and len(calls) == 3
    cfg.unlink()   # the file gone: back to the default
    monkeypatch.delenv("SALA_TZ")
    assert TZ.setting() == ""


# ── the page's half: static/shared.js formats in the zone api/config told, and in the viewer's own when it told none ───────────────
NODE = shutil.which("node")
SHARED = (Path(__file__).resolve().parent.parent / "src" / "sala_web" / "static" / "shared.js").read_text()
ZONE_JS = SHARED[SHARED.index("const zone = {"):SHARED.index('// "5 min ago" for a time t (epoch ms)')]


def run_node(body: str, viewer_tz: str) -> dict:
    script = ZONE_JS + "\nconst d = new Date(Date.UTC(2026, 9, 15, 15, 30));\n" + body
    env = {"PATH": "/usr/bin:/bin:/usr/local/bin", "TZ": viewer_tz}
    return json.loads(subprocess.run([NODE, "-e", script], capture_output=True, text=True, check=True, timeout=30, env=env).stdout)


@pytest.mark.skipif(not NODE, reason="node is not installed")
def test_the_page_formats_in_the_told_zone_and_in_the_viewers_when_none_is_told():
    body = """
const f = zoneFormat("en-GB", { hour: "2-digit", minute: "2-digit", hour12: false });
const out = {};
out.unset = f.format(d) + " " + zoneLabel(d);                     // nothing told: the viewer's zone
applyZone({ timezone: "Asia/Dubai", tzLabel: "+04", tzOffsetMin: 240 });
out.dubai = f.format(d) + " " + zoneLabel(d);                     // en-US spells Dubai "GMT+4": the server's label stands in
applyZone({ timezone: "Europe/Berlin", tzLabel: "CEST", tzOffsetMin: 120 });
out.berlin = f.format(d);
applyZone({ timezone: "Not/AZone", tzLabel: "", tzOffsetMin: null });
out.bad = f.format(d);                                            // a name this browser does not know: the viewer's zone, no error
applyZone({});
out.cleared = f.format(d);
console.log(JSON.stringify(out));
"""
    out = run_node(body, "America/Los_Angeles")
    assert out["unset"] == "08:30 PDT" and out["dubai"] == "19:30 +04" and out["berlin"] == "17:30"
    assert out["bad"] == "08:30" and out["cleared"] == "08:30"
    out = run_node(body, "Asia/Kolkata")
    assert out["unset"].startswith("21:00 ") and out["cleared"] == "21:00"
