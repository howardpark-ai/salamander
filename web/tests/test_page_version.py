"""The version an open page compares to know whether to ask for a reload (pageversion.py), and how the page uses it.

Held here, with no browser:
- the version is a hash of the CONTENT of the page's files: the same files give the same version whatever their modification
  times and whichever commit the server runs (a restart that changes nothing the browser loads shows no "Reload" strip);
- a one-byte change to a script, a markup file or any non-stylesheet file under static/ changes the page version, and a file
  added, removed or renamed does too; a style sheet's change leaves the page version alone and changes the styles version;
- /api/config, the served page and the stream's first event all carry the same pair;
- the page's own script: the strip is shown only for a different page version, a different styles version is swapped in place, and
  the title suffix, zone, scopes and Shell names are applied from the one version check that runs every 60 s.

The same behavior in a real page is in test_page_version_browser.py.
"""

from __future__ import annotations

import os
import re
from pathlib import Path

import pytest
from starlette.testclient import TestClient

from sala_web import app as A
from sala_web import pageversion as PV
from sala_web.app import STATIC, create_app
from sala_web.config import Settings

JS = (STATIC / "app.js").read_text()


@pytest.fixture
def tree(tmp_path):
    root = tmp_path / "static"
    (root / "vendor").mkdir(parents=True)
    (root / "index.html").write_text("<html>{{build}}</html>")
    (root / "app.js").write_text("var a = 1;")
    (root / "vendor" / "lib.min.js").write_text("var lib = 1;")
    (root / "style.css").write_text("body { margin: 0; }")
    (root / "extra.css").write_text("p { margin: 0; }")
    return root


def test_the_same_files_give_the_same_version_whatever_their_times(tree):
    before = PV.versions(tree)
    for p in tree.rglob("*"):
        if p.is_file():
            os.utime(p, (1_000_000, 1_000_000))
    assert PV.versions(tree) == before   # a fast-forward rewrote every file with the same bytes
    for p in tree.rglob("*"):
        if p.is_file():
            p.write_bytes(p.read_bytes())   # rewritten in place: a new time, the same content
    assert PV.versions(tree) == before


@pytest.mark.parametrize("name", ["app.js", "index.html", "vendor/lib.min.js"])
def test_a_one_byte_change_to_a_script_or_markup_file_changes_the_page_version_only(tree, name):
    page, styles = PV.versions(tree)
    f = tree / name
    f.write_bytes(f.read_bytes() + b" ")
    page2, styles2 = PV.versions(tree)
    assert page2 != page and styles2 == styles


def test_a_style_only_change_moves_the_styles_version_and_not_the_page_version(tree):
    page, styles = PV.versions(tree)
    (tree / "style.css").write_text("body { margin: 4px; }")
    page2, styles2 = PV.versions(tree)
    assert page2 == page and styles2 != styles
    (tree / "extra.css").unlink()   # a sheet taken away is a style change too
    page3, styles3 = PV.versions(tree)
    assert page3 == page and styles3 not in (styles, styles2)
    (tree / "new.css").write_text("a {}")   # a new sheet: only its link in the markup (a page change) makes the page ask for it
    page4, styles4 = PV.versions(tree)
    assert page4 == page and styles4 != styles3


def test_a_file_added_removed_or_renamed_changes_the_page_version(tree):
    page, _ = PV.versions(tree)
    (tree / "more.js").write_text("var m = 1;")
    added, _ = PV.versions(tree)
    assert added != page
    (tree / "more.js").rename(tree / "other.js")   # the same bytes under another name
    renamed, _ = PV.versions(tree)
    assert renamed not in (page, added)
    (tree / "other.js").unlink()
    assert PV.versions(tree)[0] == page


def test_a_file_that_vanishes_during_the_listing_is_skipped(tree, monkeypatch):
    real = PV._file_hash

    def gone(p, st):
        if p.name == "app.js":
            raise FileNotFoundError(p)
        return real(p, st)

    monkeypatch.setattr(PV, "_file_hash", gone)
    assert PV.versions(tree)[0]   # no exception: a deploy in progress, the next call sees the new tree


def _client(tmp_path, monkeypatch, static: Path, commit: str) -> TestClient:
    monkeypatch.setattr(A, "STATIC", static)
    monkeypatch.setattr(A, "_git_commit", lambda *_a, **_k: commit)
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True, exist_ok=True)
    (claude / "projects").mkdir(exist_ok=True)
    s = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude,
                 tmux_socket_name="salaweb-pytest-unused", roles_cmd=["false"])
    return TestClient(create_app(s))


def test_a_server_restart_on_a_new_commit_with_the_same_page_files_gives_the_same_version(tmp_path, monkeypatch, tree):
    first = _client(tmp_path, monkeypatch, tree, "aaaaaaa").get("/api/config").json()
    for p in tree.rglob("*"):
        if p.is_file():
            os.utime(p, (2_000_000, 2_000_000))   # and the files were checked out again
    second = _client(tmp_path, monkeypatch, tree, "bbbbbbb").get("/api/config").json()
    assert first["commit"] == "aaaaaaa" and second["commit"] == "bbbbbbb"   # the server did restart on other code
    assert second["version"] == first["version"] and second["styles"] == first["styles"]


def test_the_config_the_page_and_the_stream_carry_the_same_pair(tmp_path, monkeypatch):
    c = _client(tmp_path, monkeypatch, STATIC, "ccccccc")
    cfg = c.get("/api/config").json()
    html = c.get("/").text
    assert f'content="{cfg["version"]}"' in html and f'content="{cfg["styles"]}"' in html
    assert cfg["version"] != cfg["styles"]
    # the terminal page names its sheets by the styles version too
    term = c.get("/terminal").text
    assert re.search(r'href="static/termclip\.css\?v=%s"' % cfg["styles"], term) and "{{" not in term


def test_every_local_sheet_link_takes_the_styles_version_and_no_script_does():
    for name in ("index.html", "terminal.html"):
        text = (STATIC / name).read_text()
        sheets = re.findall(r'<link rel="stylesheet" href="(static/[^"]+)"', text)
        assert sheets and all(h.endswith(".css?v={{sv}}") for h in sheets), (name, sheets)
        scripts = re.findall(r'<script src="(static/[^"]+)"', text)
        assert all(h.endswith(".js?v={{v}}") for h in scripts), (name, scripts)


def test_the_page_swaps_styles_in_place_and_shows_the_strip_only_for_a_page_change():
    assert "const LOADED_STYLES = document.querySelector('meta[name=\"sala-web-styles\"]')" in JS
    swap = JS[JS.index("function swapStyles(v)"):JS.index("function noteVersion(v, styles)")]
    assert "location.reload" not in swap and "$(\"#update-banner\")" not in swap and "reloadPage" not in swap
    assert "old.after(n)" in swap and 'addEventListener("load", () => old.remove())' in swap   # the old sheet goes only once the new one has loaded
    note = JS[JS.index("function noteVersion(v, styles)"):JS.index("function safeToAutoReload()")]
    assert "if (styles) swapStyles(styles);" in note
    # the strip is judged by the page version alone, after the swap, which never reaches it
    assert note.index("swapStyles(styles)") < note.index('$("#update-banner").hidden = false')
    assert "styles" not in note[note.index("if (!v ||"):]


def test_the_version_check_applies_what_the_config_tells_and_there_is_one_timer():
    apply = JS[JS.index("function applyConfig(c)"):JS.index("async function checkVersion()")]
    for want in ("state.terminalUrl", "state.shellSession", "state.host", "ns.scopes", "state.defaultScope", "paintBrand(", "applyZone(c)",
                 "paintShellNames()", "nsRenderScopes()", "noteVersion(c.version, c.styles)"):
        assert want in apply, want
    check = JS[JS.index("async function checkVersion()"):JS.index("const checkSoon")]
    assert "applyConfig(await r.json())" in check
    # the start and the 60 s check read the config through the same function; no second timer reads it
    assert JS.count("applyConfig(") == 3   # its definition, the start, the check
    assert JS.count("setInterval(checkVersion, 60000)") == 1
    assert len(re.findall(r'fetch\("api/config"', JS)) == 1 and len(re.findall(r'apiFetch\("api/config"', JS)) == 1
    # the stream's first event hands both versions to the same function
    assert "noteVersion(d.version, d.styles)" in JS
