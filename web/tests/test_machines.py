"""The Overview's Machines tab, server side (machines.py, GET /api/machines): the machine cards, read from the
files stackshot, the fleet and machine-follow write. Nothing here calls GitHub, ssh or a machine, and no test reads this box's real files:
a made-up fleet is written to a temporary folder (machines_world.py) and removed when the test ends.

What a wrong answer costs: a machine missing or in the wrong place (a new machine that needs a change to this app, a host drawn twice), a version
row that says "latest" when the machine is behind or shows the fleet's old reading over a live one, a failed update that never reaches the
page, a "follows" line that is guessed instead of read, a credential or file path in an answer, a footer date that is not the reading's own
time, or a missing file turning the tab into a 500 instead of a section that says "no reading yet".
"""

from __future__ import annotations

import json
import time
from pathlib import Path

from starlette.testclient import TestClient

from machines_world import FOLLOWED_AT, TOML, settings, world
from sala_web import machines as M
from sala_web.app import create_app
from sala_web.config import Settings


def collect(w, toml=None, **over) -> dict:
    return M.collect(settings(w, **over), toml=TOML if toml is None else toml, now=w.now)


def card(d: dict, name: str) -> dict:
    return next(c for c in d["machines"]["cards"] if c["name"] == name)


def rows(d: dict, name: str) -> list[tuple]:
    return [(r["package"], r["version"], r["state"], r["text"]) for r in card(d, name)["rows"]]


# ── which machines, in which order ───────────────────────────────────────────
def test_the_machines_are_the_publisher_then_the_fleet_by_letter_then_the_ssh_hosts_with_no_machine_listed_in_the_app():
    with world() as w:
        d = collect(w)
    assert [c["name"] for c in d["machines"]["cards"]] == ["alpha-box", "beta-box", "gamma-box", "delta-box", "eps-host", "zeta-host"]
    # a host that is also a fleet machine is that machine's one card (eps-host is in the names file and in the ssh list, twice)
    assert [c["name"] for c in d["machines"]["cards"]].count("eps-host") == 1


def test_a_machine_that_is_only_in_the_names_file_or_only_in_the_settings_appears_and_the_publisher_letter_is_the_settings():
    with world() as w:
        d = collect(w, toml={"fleet": {"publisher_letter": "b"}, "machines_panel": {"ssh_hosts": "solo-host"}})
    assert [c["name"] for c in d["machines"]["cards"]] == ["beta-box", "alpha-box", "gamma-box", "delta-box", "eps-host", "solo-host"]
    assert card(d, "beta-box")["follow"]["text"] == "the machine the others follow"   # the publisher is the machine the others follow, whichever letter it has
    assert card(d, "solo-host")["rows"] == []                                        # an ssh host versions.json has not read yet: a card with no rows


def test_a_fleet_state_name_beats_the_names_file_and_a_letter_with_no_name_is_its_own_name():
    with world() as w:
        (w.state / "clients" / "fleet" / "d" / "machine.json").write_text(json.dumps({"letter": "d", "fleet": "delta-renamed"}))
        names = M.fleet_names(settings(w))
        assert names["d"] == "delta-renamed" and names["c"] == "gamma-box"
    assert M.machines_order({"a": "x"}, [], "q") == [("q", "q"), ("x", "a")]


# ── the version rows and their merge ─────────────────────────────────────────
def test_the_fleet_rows_say_latest_update_or_offline_by_the_numbers_and_the_pullers_state():
    with world() as w:
        d = collect(w)
    assert rows(d, "alpha-box") == [("claude code", "2.1.5", "latest", "latest ✓"), ("gbrain", "0.5.0", "update", "→ 0.6.0")]   # a package of the publisher alone shows there
    assert rows(d, "beta-box") == [("claude code", "2.1.2", "update", "→ 2.1.5")]                                                # and not on another machine
    assert rows(d, "delta-box") == [("claude code", "2.1.5", "offline", "offline")]                                               # its puller is not checking in
    assert rows(d, "gamma-box") == []


def test_a_machine_that_is_also_an_ssh_host_shows_the_ssh_row_while_the_host_answers():
    with world() as w:
        d = collect(w)
    # the fleet says claude code 2.1.1; the host, read live, says 2.1.4 and also has gbrain
    assert rows(d, "eps-host") == [("claude code", "2.1.4", "update", "→ 2.1.5"), ("gbrain", "0.5.0", "update", "→ 0.6.0")]


def test_when_the_host_stops_answering_the_fleet_row_wins_and_the_hosts_last_rows_only_fill_what_the_fleet_does_not_know():
    with world(eps_up=False) as w:
        d = collect(w)
    assert rows(d, "eps-host") == [("claude code", "2.1.1", "update", "→ 2.1.5"), ("gbrain", "0.5.0", "offline", "offline")]
    # a host with no fleet row of its own: its last versions show as offline
    assert rows(d, "zeta-host") == [("claude code", "2.0.0", "offline", "offline")]


def test_an_unreachable_host_that_never_answered_is_one_offline_row_and_an_unknown_latest_is_said_so():
    host = {"name": "h", "reachable": False, "packages": {}}
    assert M.host_rows(host, [{"name": "claude code", "latest": "1.0.0"}]) == {"": {"package": "", "version": "", "state": "offline", "text": "offline"}}
    assert M.card_rows("", "a", host, [{"name": "claude code", "latest": "1.0.0"}])[0]["text"] == "offline"
    up = M.host_rows({"name": "h", "packages": {"x": "1.0"}}, [{"name": "x", "latest": "?"}])
    assert up["x"]["state"] == "unknown" and up["x"]["text"] == "latest unknown"
    assert M._behind("1.9.0", "1.10.0") is True and M._behind("1.10.0", "1.9.0") is False and M._behind("x", "1.0") is False and M._behind("1.0", "") is False


# ── a failed update or setup ─────────────────────────────────────────────────
def test_a_failed_setup_and_a_failed_update_are_lines_in_the_card_and_mark_it_and_only_the_latest_attempt_of_a_package_counts():
    with world(now=1793775000.0) as w:     # Wed Nov 4th 2026, 10:50 +04
        d = collect(w)
    b = card(d, "beta-box")
    assert b["alert"] is True
    assert [(a["kind"], a["detail"]) for a in b["alerts"]] == [("setup", "step 4"), ("update", "claude code 2.1.2")]   # gbrain failed once, then succeeded: not listed
    setup, upd = b["alerts"]
    assert setup["tip"].startswith("setup failed at step 4 ") and "+04" in setup["tip"] and "TOKEN=***" in setup["tip"] and "abc123secret" not in setup["tip"]
    assert upd["tip"].startswith("claude code update 2.1.1 → 2.1.2 failed ") and upd["tip"].endswith(": network down")   # the later attempt's reason
    assert all(not card(d, n)["alert"] and card(d, n)["alerts"] == [] for n in ("alpha-box", "gamma-box", "delta-box", "eps-host"))


def test_a_malformed_machine_view_has_no_alerts_and_does_not_stop_the_card():
    assert M.machine_alerts({"setup": "text", "updates": "text"}) == (None, [])
    assert M.machine_alerts({"setup": {"ok": True}, "updates": [1, {"what": ""}, {"what": "x", "ok": False}]}) == (None, [{"what": "x", "ok": False}])
    assert M.card_alerts({"updates": [{"what": "x", "ok": False, "at": "not a time"}]}, 0.0)[0]["tip"] == "x update failed at an unknown time: no reason given"


# ── a box's stackshot checkout is judged by where the box is ─────────────────
SC_OLD, SC_NEW = "c" * 40, "d" * 40
CK_FAILED = {"what": "stackshot checkout", "ok": False, "at": "2026-11-06T00:00:00Z", "reason": "the server's commit is not on origin",
             "from": SC_OLD[:12], "to": SC_NEW[:12]}


def test_a_failed_checkout_attempt_is_red_only_while_the_box_is_elsewhere_and_clears_when_its_commit_matches_the_servers():
    elsewhere = {"updates": [CK_FAILED], "stackshot": SC_OLD}
    assert M.machine_alerts(elsewhere, SC_NEW)[1] == [CK_FAILED]                              # the box is elsewhere: red
    at_server = {**elsewhere, "stackshot": SC_NEW}
    assert M.machine_alerts(at_server, SC_NEW) == (None, [])                                  # the box got to the server's commit another way: clear, nothing re-run
    assert M.machine_alerts({**elsewhere, "stackshot": SC_NEW.upper()}, SC_NEW)[1] == []      # case does not matter
    assert M.machine_alerts(at_server, SC_OLD)[1] == [CK_FAILED]                              # the server moved on: red again until the box catches up
    assert M.machine_alerts(elsewhere, "")[1] == [CK_FAILED]                                  # the server's commit unknown: the last attempt decides
    assert M.machine_alerts(elsewhere)[1] == [CK_FAILED]                                      # the server argument is optional
    assert M.machine_alerts({"updates": [CK_FAILED]}, SC_NEW)[1] == [CK_FAILED]              # the box reports no commit: the last attempt decides
    assert M.machine_alerts({"updates": [CK_FAILED], "stackshot": ["x"]}, SC_NEW)[1] == [CK_FAILED]   # a malformed commit is no commit
    assert M.machine_alerts({"stackshot": SC_NEW, "updates": [dict(CK_FAILED, ok=True)]}, SC_NEW)[1] == []
    assert M.machine_alerts({"stackshot": SC_NEW, "updates": []}, SC_NEW) == (None, [])      # no attempt, nothing to drop


def test_only_the_checkout_is_judged_by_commit_other_packages_and_the_setup_run_keep_their_last_attempt():
    other = {"what": "stackshot puller", "ok": False, "at": "2026-11-06T00:00:00Z", "reason": "x", "from": "5", "to": "6"}
    m = {"stackshot": SC_NEW, "updates": [CK_FAILED, other], "setup": {"ok": False, "step": 2, "at": "2026-11-06T00:00:00Z", "reason": "r"}}
    setup, ups = M.machine_alerts(m, SC_NEW)
    assert setup is not None and ups == [other]


def test_a_reload_failure_of_the_commit_the_box_runs_now_stays_red_and_an_older_one_clears_with_the_match():
    reload_here = dict(CK_FAILED, reason="reload failed: the new code did not start")       # `to` is the commit the box is at now
    assert M.machine_alerts({"stackshot": SC_NEW, "updates": [reload_here]}, SC_NEW)[1] == [reload_here]   # at the server's commit but not running it: red
    older = dict(reload_here, to=SC_OLD[:12])
    assert M.machine_alerts({"stackshot": SC_NEW, "updates": [older]}, SC_NEW)[1] == []     # the failed reload was of an older commit: clear
    assert M.machine_alerts({"stackshot": SC_OLD, "updates": [older]}, SC_NEW)[1] == [older]   # not at the server's commit: red either way


def test_the_servers_commit_is_read_from_the_advertised_commit_file_and_anything_else_is_unknown(tmp_path):
    f = tmp_path / "clients" / "advertised-commit"
    assert M.server_commit(tmp_path) == "" and M.server_commit(None) == ""                   # no file
    f.parent.mkdir()
    f.write_text(SC_NEW + "\n")
    assert M.server_commit(tmp_path) == SC_NEW
    f.write_text(SC_NEW.upper() + "\n")
    assert M.server_commit(tmp_path) == SC_NEW
    for bad in ("", "not a commit\n", SC_NEW[:12] + "\n", SC_NEW + "\n" + SC_NEW + "\n", SC_NEW + "x\n", "z" * 40 + "\n"):
        f.write_text(bad)
        assert M.server_commit(tmp_path) == "", bad
    f.write_bytes(b"\xff\xfe\x00")
    assert M.server_commit(tmp_path) == ""                                                    # not text
    f.write_text("a" * 5000)
    assert M.server_commit(tmp_path) == ""                                                    # oversized


def test_the_card_goes_red_and_clears_by_itself_as_the_boxes_commit_and_the_servers_meet_and_the_tab_only_reads():
    with world(now=1793775000.0) as w:
        mj = w.state / "clients" / "fleet" / "c" / "machine.json"
        adv = w.state / "clients" / "advertised-commit"
        mj.parent.mkdir(parents=True, exist_ok=True)

        def write(box_commit, server, updates=(CK_FAILED,)):
            mj.write_text(json.dumps({"letter": "c", "fleet": "gamma-box", "stackshot": box_commit, "updates": list(updates)}))
            if server is None:
                adv.unlink(missing_ok=True)
            else:
                adv.write_text(server + "\n")
            return card(collect(w), "gamma-box")

        red = write(SC_OLD, SC_NEW)
        assert red["alert"] is True and [(a["kind"], a["detail"]) for a in red["alerts"]] == [("update", "stackshot checkout " + SC_NEW[:12])]
        assert "is not on origin" in red["alerts"][0]["tip"]
        green = write(SC_NEW, SC_NEW)
        assert green["alert"] is False and green["alerts"] == []                               # the failed attempt is still on record; the card no longer shows it
        assert write(SC_NEW, SC_OLD)["alert"] is True                                           # the server moved on
        assert write(SC_NEW, None)["alert"] is True                                             # no advertised-commit file: the last attempt decides
        assert write(SC_NEW, SC_NEW, [dict(CK_FAILED, reason="reload failed: boom")])["alert"] is True
        before = sorted(str(p.relative_to(w.root)) + str(p.stat().st_mtime_ns) for p in w.root.rglob("*") if p.is_file())
        collect(w)
        after = sorted(str(p.relative_to(w.root)) + str(p.stat().st_mtime_ns) for p in w.root.rglob("*") if p.is_file())
        assert before == after                                                                  # read-only, as the rest of the tab


# ── how a machine stays current ──────────────────────────────────────────────
def test_the_last_line_is_read_from_the_follow_list_and_its_records_never_written_into_the_app():
    with world() as w:
        d = collect(w)
    f = {c["name"]: c["follow"] for c in d["machines"]["cards"]}
    assert f["alpha-box"]["text"] == "the machine the others follow" and f["alpha-box"]["kind"] == "publisher"
    for n in ("beta-box", "gamma-box", "delta-box"):
        assert f[n] == {"kind": "self", "text": "updates itself", "tip": ""}
    assert f["eps-host"] == {"kind": "follows", "text": "follows alpha-box · last 10:43", "tip": "last followed Wed Nov 4th 10:43 +04"}   # the zone's label, from at_epoch
    assert f["zeta-host"]["text"] == "follows alpha-box" and f["zeta-host"]["tip"] == "no record of a follow yet"                       # listed, never followed


def test_a_follow_list_that_cannot_be_read_says_so_rather_than_guessing_and_the_publisher_still_reads_as_one():
    with world() as w:
        w.follow.write_text("this is [not toml")
        d = collect(w)
    f = {c["name"]: c["follow"] for c in d["machines"]["cards"]}
    assert f["alpha-box"]["text"] == "the machine the others follow"
    assert f["eps-host"]["kind"] == f["beta-box"]["kind"] == "unknown" and f["beta-box"]["text"] == "update source not read"


def test_the_source_is_the_lists_run_on_and_a_machines_own_run_on_makes_it_the_one_the_others_follow(tmp_path):
    f = M.follow_line("m1", "pub", {"run_on": "src", "machines": {"m1": {}}}, tmp_path)
    assert f["text"] == "follows src" and f["kind"] == "follows"
    assert M.follow_line("src", "pub", {"run_on": "src", "machines": {}}, tmp_path)["kind"] == "publisher"
    assert M.follow_line("m2", "pub", {"machines": {"m2": {"run_on": "m2"}}}, tmp_path)["kind"] == "publisher"
    assert M.follow_line("m3", "pub", {"machines": {"m3": {}}}, tmp_path)["text"] == "follows pub"   # no run_on in the list: the publisher it is
    (tmp_path / "m4.json").write_text(json.dumps({"at_epoch": FOLLOWED_AT}))
    assert M.follow_line("m4", "pub", {"run_on": "src", "machines": {"m4": {}}}, tmp_path)["text"] == "follows src · last 10:43"
    (tmp_path / "m5.json").write_text("{not json")
    assert M.follow_line("m5", "pub", {"run_on": "src", "machines": {"m5": {}}}, tmp_path)["text"] == "follows src"
    assert M.follow_line("../x", "pub", {"run_on": "src", "machines": {"../x": {}}}, tmp_path)["text"] == "follows src"   # a name is never a path


# ── no reading yet ───────────────────────────────────────────────────────────
def test_a_missing_versions_file_makes_the_machines_section_say_no_reading_and_the_footer_has_no_time():
    with world() as w:
        (w.state / "site" / "versions.json").unlink()
        d = collect(w)
    assert d["machines"]["ok"] is False and d["machines"]["cards"] == [] and "versions" in d["machines"]["reason"] and d["updated"] is None


def test_nothing_named_anywhere_is_no_machines_and_no_path_set_is_no_reading_not_an_error():
    with world() as w:
        d = collect(w, toml={}, fleet_names_file=None, follow_machines_file=None, stackshot_state=w.state / "nowhere")
    assert d["machines"]["ok"] is False and d["updated"] is None
    with world() as w:
        (w.state / "clients" / "fleet" / "a" / "machine.json").write_text("{broken")
        d = collect(w)
    assert d["machines"]["ok"] is True and card(d, "alpha-box")["alerts"] == [] and card(d, "alpha-box")["name"] == "alpha-box"   # a broken machine.json is skipped, never raised


def test_a_state_file_over_the_size_cap_is_not_read(tmp_path):
    big = tmp_path / "big.json"
    big.write_text(json.dumps({"x": "y" * (M.MAX_BYTES + 10)}))
    assert M._json(big) is None and M._json(None) is None and M._json(tmp_path / "missing.json") is None


# ── what the answer carries ──────────────────────────────────────────────────
def test_the_answer_carries_no_token_no_session_id_and_no_path_and_no_runner_section():
    with world() as w:
        d = collect(w)
        text = json.dumps(d)
        for secret in ("11111111-2222-4333-8444-555555555555", "secret-session-name", "abc123secret", str(w.root), "machine.json"):
            assert secret not in text, secret
        assert set(d) == {"generated", "tzLabel", "updated", "machines"}        # sala reads no runner file: the answer has no "runners" key
        assert "runners" not in d and "runner" not in text.lower()


def test_the_age_is_the_versions_files_own_time_and_a_time_label_is_the_zone_not_a_literal():
    with world(now=1793775000.0) as w:
        d = collect(w)
    assert d["generated"] == 1793775000.0 and d["updated"] == 1793775000.0 - 240 and d["tzLabel"] == "+04"
    assert M.ago(0) == "just now" and M.ago(59) == "just now" and M.ago(60) == "1m ago" and M.ago(3600) == "1h ago" and M.ago(48 * 3600) == "2d ago"
    assert M.full_time(FOLLOWED_AT) == "Wed Nov 4th 10:43 +04" and M.clock(FOLLOWED_AT) == "10:43"


# ── the route and the settings ───────────────────────────────────────────────
def test_the_route_answers_json_with_no_store_and_never_a_500_when_nothing_exists(tmp_path):
    s = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "st")     # the autouse fixture points every path at a place that does not exist
    r = TestClient(create_app(s)).get("/api/machines")
    assert r.status_code == 200 and r.headers["cache-control"] == "no-store"
    d = r.json()
    assert d["machines"]["ok"] is False and "runners" not in d and d["updated"] is None


def test_the_route_serves_the_worlds_answer_and_only_reads(tmp_path):
    with world() as w:
        before = sorted(str(p.relative_to(w.root)) + str(p.stat().st_mtime_ns) for p in w.root.rglob("*") if p.is_file())
        s = settings(w, socket=tmp_path / "s.sock", state_dir=tmp_path / "st")
        client = TestClient(create_app(s))
        d = client.get("/api/machines").json()
        assert [c["name"] for c in d["machines"]["cards"]][:2] == ["alpha-box", "beta-box"] and "runners" not in d
        assert client.post("/api/machines").status_code in (404, 405)
        after = sorted(str(p.relative_to(w.root)) + str(p.stat().st_mtime_ns) for p in w.root.rglob("*") if p.is_file())
    assert before == after                                                   # nothing written, nothing touched


def test_the_settings_find_the_files_from_stackshots_own_settings_file_and_the_environment(tmp_path, monkeypatch):
    for v in ("SALA_WEB_STACKSHOT_STATE", "SALA_WEB_FLEET_NAMES", "SALA_WEB_MACHINE_FOLLOW_MACHINES", "SALA_WEB_MACHINE_FOLLOW_STATE"):
        monkeypatch.delenv(v)
    cfg, home = tmp_path / "config", tmp_path / "state-home"
    (cfg / "stackshot").mkdir(parents=True)
    (cfg / "stackshot" / "stackshot.toml").write_text(f'[paths]\nstate = "{tmp_path}/ss-state"\nfleet_names = "{tmp_path}/hub/ops/fleet-names.tsv"\n')
    monkeypatch.setenv("XDG_CONFIG_HOME", str(cfg))
    monkeypatch.setenv("XDG_STATE_HOME", str(home))
    s = Settings()
    assert s.stackshot_state == tmp_path / "ss-state" and s.fleet_names_file == tmp_path / "hub" / "ops" / "fleet-names.tsv"
    assert s.follow_machines_file == tmp_path / "hub" / "ops" / "claude" / "machine-follow" / "machines.toml"   # beside the names file's folder
    assert s.follow_state_dir == home / "machine-follow"
    monkeypatch.setenv("SALA_WEB_STACKSHOT_STATE", str(tmp_path / "other"))
    monkeypatch.setenv("SALA_WEB_MACHINE_FOLLOW_MACHINES", str(tmp_path / "m.toml"))
    s = Settings()
    assert s.stackshot_state == tmp_path / "other" and s.follow_machines_file == tmp_path / "m.toml"
    (cfg / "stackshot" / "stackshot.toml").unlink()
    monkeypatch.delenv("SALA_WEB_STACKSHOT_STATE")
    monkeypatch.delenv("SALA_WEB_MACHINE_FOLLOW_MACHINES")
    s = Settings()
    assert s.stackshot_state == home / "stackshot" and s.fleet_names_file is None and s.follow_machines_file is None   # no settings file: the XDG default, no names


# ── the page ─────────────────────────────────────────────────────────────────
STATIC = Path(__file__).resolve().parents[1] / "src" / "sala_web" / "static"


def test_the_page_has_the_third_tab_its_panel_its_files_and_the_hash_registered_in_app_js():
    import re
    html = (STATIC / "index.html").read_text()
    assert re.search(r'<a id="ov-tab-machines"[^>]*href="#machines"[^>]*aria-selected="false"', html)
    assert [m for m in re.findall(r'<a id="ov-tab-(\w+)"', html)] == ["sessions", "schedules", "machines", "usage"]         # Machines after Agents and Schedules, Usage analysis last
    assert 'id="ov-machines"' in html and 'id="mc-reload"' in html and 'href="static/machines.css?v={{v}}"' in html and 'src="static/machines.js?v={{v}}"' in html
    js = (STATIC / "app.js").read_text()
    assert 'const OV_TABS = ["sessions", "schedules", "machines", "usage"]' in js and "machinesHash" in js and "machines.start()" in js and "machines.stop()" in js
    assert 'a.hash === "#machines"' in js                                    # a click on the tab's link is sala's own (go)
    fixture_names = "alpha-box|beta-box|example-org"   # the fixture machines and organization of this suite: the page's own files carry no machine or organization name
    assert not re.search(fixture_names, (STATIC / "machines.js").read_text() + (STATIC / "machines.css").read_text()), "no machine or owner is named in the page"


def test_every_machines_css_rule_is_scoped_to_its_panel_and_the_page_never_names_a_machine():
    import re
    css = (STATIC / "machines.css").read_text()
    body = re.sub(r"/\*.*?\*/", "", css, flags=re.S)
    def top_level_commas(text: str) -> list[str]:   # a selector list split at its own commas, not the ones inside :is(…)
        out, depth, cur = [], 0, ""
        for ch in text:
            depth += (ch == "(") - (ch == ")")
            if ch == "," and depth == 0:
                out.append(cur.strip())
                cur = ""
            else:
                cur += ch
        return out + [cur.strip()]
    selectors = [s for chunk in re.findall(r"(?:^|[{}])\s*([^{}@][^{}]*)\{", body) for s in top_level_commas(chunk) if not s.startswith("@container")]   # the container block's own rules are checked as the others
    assert len(selectors) > 20 and all(s.startswith("#ov-machines") for s in selectors), [s for s in selectors if not s.startswith("#ov-machines")]
    assert "@container mcpanel (max-width: 640px)" in css
    assert "overflow-x" not in css and "min-width: 0" in css
