"""Mockup pages: GET /mockup/<n> serves what `sala mockup add` stored, in a sandbox (mockup.py, README *Canvas pages*).

The route tests drive the app in process (starlette's TestClient). The last two tests open a served page in a real headless Chromium (the `served`
and `browser` fixtures of conftest.py; skipped where there is none) and let the page's own script try to reach sala's API and cookies.
"""

import os
import re
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

import pytest
from starlette.testclient import TestClient

from sala_web import mockup as MK
from sala_web.app import create_app
from sala_web.config import Settings

STATIC = Path(__file__).resolve().parent.parent / "src" / "sala_web" / "static"
DOCS = Path(__file__).resolve().parent.parent.parent / "docs"
SALA = DOCS.parent / "bin" / "salamander"

# the policy, spelled out once more here on purpose: a change to MK.CSP must change this line too, and a reader sees what the sandbox allows
EXPECTED_CSP = ("sandbox allow-scripts; default-src 'none'; script-src 'unsafe-inline'; "
                "style-src 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com data:; "
                "img-src data:; media-src data:; connect-src 'none'; frame-src 'none'; worker-src 'none'; object-src 'none'; "
                "base-uri 'none'; form-action 'none'; frame-ancestors 'self'")

PAGE = ('<!doctype html><html lang="en"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width, initial-scale=1"><title>mock</title>'
        '<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter">'
        '<style>body{font-family:Inter,sans-serif;background:#eef}</style></head>'
        '<body><h1 id="h">hello ✓ mockup</h1><script>document.getElementById("h").dataset.ran="1"</script></body></html>')


def make_settings(tmp_path, **kw) -> Settings:
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True, exist_ok=True)
    (claude / "projects").mkdir(exist_ok=True)
    return Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude, sala_state_dir=tmp_path / "salastate",
                    tmux_socket_name="salaweb-pytest-unused", roles_cmd=["false"], **kw)


@pytest.fixture
def env(tmp_path):
    settings = make_settings(tmp_path)
    root = settings.mockups_dir
    root.mkdir(parents=True, mode=0o700)
    return {"client": TestClient(create_app(settings)), "root": root, "settings": settings}


def store(root: Path, n: int, text: str = PAGE) -> None:
    (root / f"{n}.html").write_text(text, encoding="utf-8")


def check_sandbox_headers(r) -> None:
    assert r.headers["content-security-policy"] == EXPECTED_CSP
    assert r.headers["x-content-type-options"] == "nosniff"
    assert r.headers["referrer-policy"] == "no-referrer"
    assert "set-cookie" not in r.headers


# -- the page ------------------------------------------------------------------------------------------------------------------------


def test_a_stored_page_is_served_as_utf8_html_with_the_sandbox_headers(env):
    store(env["root"], 1)
    r = env["client"].get("/mockup/1")
    assert r.status_code == 200
    assert r.headers["content-type"] == "text/html; charset=utf-8"
    assert r.content == MK.with_back_link(PAGE).encode("utf-8")   # the stored page plus the back link, nothing else: the viewport meta and the Google Fonts link stay
    assert r.content.replace(MK.BACK_LINK.encode(), b"", 1) == PAGE.encode("utf-8")
    assert (env["root"] / "1.html").read_text(encoding="utf-8") == PAGE   # the file itself is not touched
    check_sandbox_headers(r)
    assert r.headers["cache-control"] == "private, no-cache"


def test_the_viewport_meta_a_phone_needs_reaches_the_reader_unchanged(env):
    store(env["root"], 2)
    assert 'name="viewport" content="width=device-width, initial-scale=1"' in env["client"].get("/mockup/2").text


def test_every_page_starts_with_a_back_link_to_the_chat_route(env):
    store(env["root"], 3)
    body = env["client"].get("/mockup/3").text
    assert '<a href="../chat"' in body and "Back to sala" in body
    assert body.index("data-sala-back") < body.index('<h1 id="h">')            # at the top of the body, before the page's own content
    assert body.index("<body>") < body.index("data-sala-back")
    assert "min-height:44px" in MK.BACK_LINK and "position:fixed" not in MK.BACK_LINK   # a tap target, and in flow so it covers nothing


@pytest.mark.parametrize("page,where", [
    ('<!doctype html><html><head><title>x</title></head><p>hi</p>', "</head>"),                  # no body tag: after the head
    ('<!doctype html><p>hi</p>', "<!doctype html>"),                                              # no html: after the doctype
    ('<p>hi</p>', ""),                                                                            # nothing: first
    ('<html><head><script>var s="<body>";</script><!-- <body> --></head><body class="a">x</body></html>', '<body class="a">'),   # a tag in a script or comment is not the body
])
def test_the_back_link_goes_in_the_right_place(page, where):
    out = MK.with_back_link(page)
    assert out.count("data-sala-back") == 1 and out.replace(MK.BACK_LINK, "", 1) == page
    assert out.index(MK.BACK_LINK) == (out.index(where) + len(where) if where else 0)


# -- the return button -----------------------------------------------------------------------------------------------------------------


def test_every_bar_carries_one_return_button_in_the_bar_before_the_stored_page(env):
    store(env["root"], 3)
    root = env["root"]
    store_version(root, 3, V_OLD)
    for url, bar in [("/mockup/3", MK.history_block(3, [V_OLD])), ("/mockup/3/versions/" + V_OLD, MK.version_block(3, V_OLD))]:
        body = env["client"].get(url).text
        assert body.count("data-sala-return") == 1 and body.count("<button") == 1
        assert bar in body and bar.index("<button") < bar.index("<a ")
        assert body.index("data-sala-return") < body.index("<h1")      # chrome sala adds, ahead of the stored content
    assert "data-sala-return" in MK.BACK_LINK
    assert "data-sala-return" not in PAGE                                 # and never in the stored file


def test_the_return_button_is_named_by_a_tooltip_alone_and_has_no_text():
    btn = MK.return_button()
    assert 'title="' in btn and 'aria-label="' in btn
    from html.parser import HTMLParser

    got = []

    class P(HTMLParser):
        def handle_data(self, d):
            got.append(d)

    P().feed(btn)
    assert "".join(got).strip() == ""                                                     # an icon only: no inline explanatory text
    assert "min-height" not in btn and "width:54px;height:44px" in btn    # a tap target of at least 44 px


def test_the_return_button_intercepts_nothing_else():
    js = re.search(r'onclick="([^"]*)"', MK.return_button()).group(1)
    for word in ["popstate", "pushState", "replaceState", "beforeunload", "addEventListener", "onpopstate", "hashchange"]:
        assert word not in js and word not in MK.BACK_LINK.replace(js, "")
    assert js.startswith("if(window.history.length>1){window.history.back();return false}window.close();")   # back, else close, else home
    assert "window.location.href=new window.URL('../',window.location.href)" in js
    assert "../../../" in re.search(r'onclick="([^"]*)"', MK.return_button("../../../")).group(1)


def test_the_return_button_leaves_the_sandbox_alone(env):
    store(env["root"], 3)
    check_sandbox_headers(env["client"].get("/mockup/3"))
    assert "allow-top-navigation" not in MK.CSP and "allow-popups" not in MK.CSP and "allow-same-origin" not in MK.CSP


def test_numbers_are_the_files_and_the_largest_works(env):
    store(env["root"], 9999999999, "<p>big number</p>")
    assert env["client"].get("/mockup/9999999999").text == MK.with_back_link("<p>big number</p>")


def test_head_answers_with_the_headers_and_no_body(env):
    store(env["root"], 1)
    r = env["client"].head("/mockup/1")
    assert r.status_code == 200 and r.content == b"" and r.headers["content-type"] == "text/html; charset=utf-8"
    check_sandbox_headers(r)


def test_the_page_is_read_at_each_request_so_a_cleanup_takes_effect_at_the_next_load(env):
    store(env["root"], 4)
    assert env["client"].get("/mockup/4").status_code == 200
    (env["root"] / "4.html").unlink()
    assert env["client"].get("/mockup/4").status_code == 404


def test_a_revision_replaces_the_page_and_the_next_load_shows_it(env):
    # `sala mockup update N` writes the new page over N.html (atomically) and saves the old one as a version under versions/N/: the next
    # load shows the new one, with the no-cache header, and the versions are not listed (they are served only through the page's history)
    store(env["root"], 5, "<p>first</p>")
    assert "first" in env["client"].get("/mockup/5").text
    tmp = env["root"] / ".tmp-5-test"
    tmp.write_text("<p>second</p>", encoding="utf-8")
    (env["root"] / "versions" / "5").mkdir(parents=True)
    (env["root"] / "versions" / "5" / "20260101T000000.000000Z.html").write_text("<p>first</p>", encoding="utf-8")
    os.replace(tmp, env["root"] / "5.html")
    r = env["client"].get("/mockup/5")
    assert r.status_code == 200 and "second" in r.text and "first" not in r.text
    assert r.headers["cache-control"] == "private, no-cache"
    check_sandbox_headers(r)
    for path in ("/mockup/5/versions", "/mockup/versions/5", "/mockup/5/20260101T000000.000000Z.html"):
        assert env["client"].get(path).status_code == 404, path


# -- the 404s ------------------------------------------------------------------------------------------------------------------------


@pytest.mark.parametrize("path", ["/mockup/7", "/mockup/0", "/mockup/01", "/mockup/007", "/mockup/abc", "/mockup/-1", "/mockup/1.html",
                                  "/mockup/1/", "/mockup/1/x", "/mockup/1/../2", "/mockup/%2e%2e%2fcounter", "/mockup/counter", "/mockup/.lock",
                                  "/mockup/", "/mockup", "/mockup/99999999999", "/mockup/1%00"])
def test_an_unknown_or_malformed_address_is_a_404_that_still_carries_the_sandbox_headers(env, path):
    store(env["root"], 1)
    (env["root"] / "counter").write_text("1\n")
    r = env["client"].get(path)
    assert r.status_code == 404, path
    assert r.text == "no such Canvas"
    check_sandbox_headers(r)


def test_a_link_a_directory_and_an_oversized_file_are_not_served(env, tmp_path):
    outside = tmp_path / "outside.html"
    outside.write_text("<p>secret</p>")
    (env["root"] / "3.html").symlink_to(outside)                 # a link out of the folder
    (env["root"] / "4.html").mkdir()                             # not a regular file
    (env["root"] / "5.html").write_bytes(b"x" * (MK.MAX_BYTES + 1))
    for n in (3, 4, 5):
        r = env["client"].get(f"/mockup/{n}")
        assert r.status_code == 404, n
        check_sandbox_headers(r)


def test_a_file_that_is_not_utf8_is_refused_not_served_as_if_it_were(env):
    (env["root"] / "6.html").write_bytes(b"<p>caf\xe9</p>")
    r = env["client"].get("/mockup/6")
    assert r.status_code == 415
    check_sandbox_headers(r)


def test_no_mockup_folder_at_all_is_just_a_404(tmp_path):
    c = TestClient(create_app(make_settings(tmp_path)))
    assert c.get("/mockup/1").status_code == 404


@pytest.mark.parametrize("method", ["post", "put", "patch", "delete"])
def test_nothing_but_get_and_head_is_allowed_and_nothing_is_written(env, method):
    store(env["root"], 1)
    before = sorted(os.listdir(env["root"]))
    r = env["client"].request(method.upper(), "/mockup/1", content=b"x")
    assert r.status_code == 405 and r.headers["allow"] == "GET, HEAD"
    check_sandbox_headers(r)
    assert sorted(os.listdir(env["root"])) == before


# -- the sign-in -----------------------------------------------------------------------------------------------------------------------


def test_the_route_has_no_sign_in_of_its_own_it_sits_behind_the_proxys_like_every_other_route(env):
    # sala-web has no login: the proxy in front of the whole site is the gate (docs/web-proxy.md: everything but /tty goes to the app). So the
    # route must be served by the SAME app as /api/config (not a second listener), must neither read nor set a credential, and must answer
    # the same whatever credentials a request carries: a gate of its own would be a second scheme to keep right.
    store(env["root"], 1)
    app = env["client"].app
    paths = {r.path for r in app.routes}
    assert "/api/config" in paths and "/mockup/{n:path}" in paths
    plain = env["client"].get("/mockup/1")
    creds = env["client"].get("/mockup/1", headers={"Authorization": "Bearer x", "Cookie": "CF_Authorization=x; session=y"})
    assert plain.status_code == creds.status_code == 200 and plain.content == creds.content
    assert "set-cookie" not in plain.headers and "set-cookie" not in creds.headers and "www-authenticate" not in plain.headers
    src = (Path(MK.__file__)).read_text()
    assert not re.search(r"request\.(cookies|headers)|Authorization", src.split('"""', 2)[2]), "mockup.py must not read credentials"
    proxy_doc = (DOCS / "web-proxy.md").read_text()
    assert "everything except `/tty`" in proxy_doc.replace("\n", " ")


# -- the sandbox policy ----------------------------------------------------------------------------------------------------------------


def test_the_policy_is_the_sandbox_that_keeps_sala_out_of_reach():
    directives = {d.split(" ", 1)[0]: d.split(" ", 1)[1:] and d.split(" ", 1)[1].split() for d in MK.CSP.split("; ")}
    assert MK.CSP == EXPECTED_CSP
    assert directives["sandbox"] == ["allow-scripts"]                      # scripts run; no allow-same-origin, forms, popups, modals, navigation
    assert "allow-same-origin" not in MK.CSP and "allow-top-navigation" not in MK.CSP and "allow-forms" not in MK.CSP
    assert directives["connect-src"] == ["'none'"] and directives["default-src"] == ["'none'"]   # no fetch, XHR, WebSocket, EventSource, beacon
    assert directives["script-src"] == ["'unsafe-inline'"]                 # inline scripts only: no external script, no eval
    assert directives["style-src"] == ["'unsafe-inline'", "https://fonts.googleapis.com"]
    assert directives["font-src"] == ["https://fonts.gstatic.com", "data:"]
    assert directives["img-src"] == ["data:"]
    for d in ("form-action", "base-uri", "frame-src", "worker-src", "object-src"):
        assert directives[d] == ["'none'"], d
    assert directives["frame-ancestors"] == ["'self'"]


# -- the service worker --------------------------------------------------------------------------------------------------------------


def test_the_service_worker_leaves_mockup_pages_alone():
    src = (STATIC / "sw.js").read_text()
    code = "\n".join(line for line in src.splitlines() if not line.lstrip().startswith("//"))
    handles_fetch = re.search(r"""addEventListener\(\s*["']fetch["']|\bonfetch\b""", code)
    # today the worker has no fetch handler, so it sees no request at all: nothing to exclude, no cache, no navigation fallback
    assert not handles_fetch
    assert not re.search(r"\bcaches\b|\bCache\b|respondWith|navigationPreload|offline", code), code
    # if a handler is ever added, it has to step aside for /mockup/ first
    if handles_fetch:
        assert "/mockup/" in code and re.search(r"return;", code)
    assert "/mockup/" in src                                        # the worker's comment says why, for whoever adds a handler


# -- the history icon and the versions -----------------------------------------------------------------------------------------------------

V_OLD = "20261027T050700.000001Z"      # Tue Oct 27th 14:07 KST
V_NEW = "20261127T142709.123456Z"      # Fri Nov 27th 23:27 KST
VERSION_PAGE = PAGE.replace("hello", "earlier")


def store_version(root: Path, n: int, vid: str, text: str = VERSION_PAGE) -> None:
    d = root / "versions" / str(n)
    d.mkdir(parents=True, mode=0o700, exist_ok=True)
    (d / f"{vid}.html").write_text(text, encoding="utf-8")


def test_one_update_through_the_cli_gives_the_page_its_history_icon(env, tmp_path):
    # the real writer: `sala mockup update` saves the page it replaces, so one update is one earlier version, named by the time it was replaced
    def sala(utc: datetime, text: str, *args: str) -> None:
        run_env = {"PATH": os.environ["PATH"], "HOME": str(tmp_path / "home"), "SALA_CONFIG": "/dev/null",
                   "XDG_STATE_HOME": str(tmp_path / "xdg"), "SALA_MOCKUP_DIR": str(env["root"]), "SALA_MOCKUP_NOW": str(utc.timestamp())}
        r = subprocess.run(["bash", str(SALA), "mockup", *args, "-"], input=text, env=run_env, capture_output=True, text=True, timeout=60)
        assert r.returncode == 0, r.stderr

    sala(datetime(2026, 10, 1, tzinfo=timezone.utc), VERSION_PAGE, "add")
    assert b"data-sala-versions" not in env["client"].get("/mockup/1").content
    sala(datetime(2026, 10, 27, 5, 7, tzinfo=timezone.utc), PAGE, "update", "1")
    text = env["client"].get("/mockup/1").text
    assert "data-sala-versions" in text and "Until Tue Oct 27th 14:07 KST</a>" in text   # when it was replaced, not when it was made
    r = env["client"].get("/mockup/1/versions/20261027T050700.000000Z")
    assert r.status_code == 200 and "earlier" in r.text and "Until Tue Oct 27th 14:07 KST" in r.text


def test_the_history_icon_is_shown_exactly_when_there_is_a_saved_earlier_version(env):
    root = env["root"]
    store(root, 3)
    assert env["client"].get("/mockup/3").content == MK.with_back_link(PAGE).encode("utf-8")   # no version: as before
    (root / "versions" / "3").mkdir(parents=True)
    assert b"data-sala-versions" not in env["client"].get("/mockup/3").content                 # an empty versions folder is no history
    for vid, ids in [(V_OLD, [V_OLD]), (V_NEW, [V_NEW, V_OLD])]:
        store_version(root, 3, vid)
        r = env["client"].get("/mockup/3")
        assert r.content == MK.with_back_link(PAGE, MK.history_block(3, ids)).encode("utf-8")  # the icon is sala's, added to the bar only
        check_sandbox_headers(r)


def test_the_icon_is_inside_the_one_bar_and_has_a_name_and_no_other_row(env):
    block = MK.history_block(3, [V_OLD])
    assert block.count("<div") == 1 and block.startswith("<div data-sala-back") and block.endswith("</details></div>")
    assert block.count("<details") == 1 and 'aria-label="Earlier versions" title="Earlier versions"' in block
    assert "About these versions" not in block


def test_the_version_bar_is_one_row_and_only_its_time_may_be_cut():
    block = MK.version_block(3, V_OLD)
    assert block.count("<div") == 1 and block.endswith("</span></div>") and 'background:#161617;position:relative;display:flex">' in block
    link, when = re.findall(r'<(?:a href="[^"]*"|span data-sala-when) style="([^"]*)"', block)
    assert link.endswith(";flex:none")                                                  # the link keeps its own width
    for part in ["flex:1;", "min-width:0;", "height:44px;", "padding:0 16px 0 0;", "text-align:right;", "overflow:hidden;", "text-overflow:ellipsis"]:
        assert part in when, part


def test_the_list_is_newest_first_in_korea_time_and_links_each_version_by_its_id(env):
    root = env["root"]
    store(root, 4)
    store_version(root, 4, V_OLD)
    store_version(root, 4, V_NEW)
    text = env["client"].get("/mockup/4").text
    assert text.index(V_NEW) < text.index(V_OLD)                                        # newest first
    assert 'href="4/versions/%s"' % V_NEW in text and 'href="4/versions/%s"' % V_OLD in text
    assert "Until Fri Nov 27th 23:27 KST</a>" in text and "Until Tue Oct 27th 14:07 KST</a>" in text   # Korea time, no UTC
    assert "2026-11-27" not in text and "UTC" not in text


@pytest.mark.parametrize("vid,label", [
    ("20261101T000000.000000Z", "Sun Nov 1st 09:00 KST"),
    ("20261102T150000.000000Z", "Tue Nov 3rd 00:00 KST"),
    ("20261112T000000.000000Z", "Thu Nov 12th 09:00 KST"),
    ("20261113T000000.000000Z", "Fri Nov 13th 09:00 KST"),
    ("20261121T000000.000000Z", "Sat Nov 21st 09:00 KST"),
    ("20261122T000000.000000Z", "Sun Nov 22nd 09:00 KST"),
    ("20261123T000000.000000Z", "Mon Nov 23rd 09:00 KST"),
])
def test_the_korea_time_label_has_the_right_day_name_and_ordinal(vid, label):
    assert MK.kst_label(vid) == label


def test_a_version_is_read_only_with_the_sandbox_and_a_way_back_to_the_current_page(env):
    root = env["root"]
    store(root, 5)
    store_version(root, 5, V_OLD)
    store_version(root, 5, V_NEW)
    r = env["client"].get("/mockup/5/versions/" + V_OLD)
    assert r.status_code == 200
    assert r.headers["content-type"] == "text/html; charset=utf-8"
    assert r.content == MK.with_back_link(VERSION_PAGE, MK.version_block(5, V_OLD)).encode("utf-8")
    assert 'href="../../5"' in r.text and "Current page" in r.text
    assert b"data-sala-versions" not in r.content                                      # no history inside a version
    assert "Until Tue Oct 27th 14:07 KST</span>" in r.text
    check_sandbox_headers(r)
    assert r.headers["cache-control"] == "private, no-cache"
    assert (root / "versions" / "5" / f"{V_OLD}.html").read_text(encoding="utf-8") == VERSION_PAGE   # the file is not touched


@pytest.mark.parametrize("path", [
    "/mockup/5/versions/" + V_OLD + ".html",          # the file name, not the id
    "/mockup/5/versions/20261327T000000.000000Z",     # month 13: not a time
    "/mockup/5/versions/20261027T050700Z",            # no microseconds
    "/mockup/5/versions/20261027T050700.000001",      # no Z
    "/mockup/5/versions/..%2F..%2F5",
    "/mockup/5/versions/%2E%2E",
    "/mockup/5/versions/" + V_OLD + "/x",
    "/mockup/5/versions/",
    "/mockup/5/versions",
    "/mockup/5/versions/hello",
    "/mockup/05/versions/" + V_OLD,                   # not a canonical number
    "/mockup/6/versions/" + V_OLD,                    # page 6 has no such version
    "/mockup/0/versions/" + V_OLD,
    "/mockup/5/" + V_OLD + ".html",                   # the old address form stays a 404
])
def test_a_version_address_that_is_not_a_saved_version_is_a_404_with_the_headers(env, path):
    store(env["root"], 5)
    store_version(env["root"], 5, V_OLD)
    r = env["client"].get(path)
    assert r.status_code == 404, path
    check_sandbox_headers(r)


def test_no_other_file_is_readable_through_a_version_address(env, tmp_path):
    root = env["root"]
    store(root, 5)
    store_version(root, 5, V_OLD)
    (root / "secret.html").write_text("SECRET-PAGE", encoding="utf-8")
    (root / "counter").write_text("7", encoding="utf-8")
    outside = tmp_path / "outside.html"
    outside.write_text("SECRET-OUTSIDE", encoding="utf-8")
    vdir = root / "versions" / "5"
    (vdir / f"{V_NEW}.html").symlink_to(outside)                                      # a link in the versions folder
    (root / "versions" / "9").mkdir(parents=True)
    (root / "versions" / "9" / f"{V_OLD}.html").write_text("OTHER-PAGE-VERSION", encoding="utf-8")
    (root / "versions" / "6").symlink_to(tmp_path)                                    # a folder that is a link
    for path in ["/mockup/5/versions/" + V_NEW, "/mockup/5/versions/secret", "/mockup/5/versions/" + V_OLD + "%2F..%2F..%2F..%2Fsecret",
                 "/mockup/6/versions/" + V_OLD, "/mockup/9/versions/" + V_OLD]:
        r = env["client"].get(path)
        assert r.status_code == 404 and b"SECRET" not in r.content and b"OTHER" not in r.content, path
        check_sandbox_headers(r)
    # a dot-dot id never reaches the file system (the HTTP client would resolve "../" before the server sees it)
    assert MK.read_version(root, "5", V_OLD + "/../../../../secret") is None
    assert MK.read_version(root, "5", V_NEW) is None   # a link in the versions folder is not followed
    # the icon's list names only regular files of the CLI's form: a link named like a version is not offered
    store_version(root, 7, V_OLD)
    store_version(root, 7, V_NEW)
    (root / "versions" / "7" / f"{V_NEW}.html").unlink()
    (root / "versions" / "7" / f"{V_NEW}.html").symlink_to(outside)
    assert MK.list_versions(root, "7") == [V_OLD]
    assert b"SECRET-OUTSIDE" not in env["client"].get("/mockup/5").content


def test_a_version_is_read_only_nothing_but_get_and_head_is_allowed(env):
    store(env["root"], 5)
    store_version(env["root"], 5, V_OLD)
    for method in ["post", "put", "patch", "delete"]:
        r = getattr(env["client"], method)("/mockup/5/versions/" + V_OLD)
        assert r.status_code == 405, method
        check_sandbox_headers(r)
    assert (env["root"] / "versions" / "5" / f"{V_OLD}.html").read_text(encoding="utf-8") == VERSION_PAGE


def test_a_page_with_versions_still_serves_the_same_bytes_it_always_did_apart_from_the_bar(env):
    store(env["root"], 8)
    store_version(env["root"], 8, V_OLD)
    store_version(env["root"], 8, V_NEW)
    body = env["client"].get("/mockup/8").text
    stripped = body.replace(MK.history_block(8, [V_NEW, V_OLD]), "", 1)   # the one bar (back link, icon, list) is the only addition
    assert stripped == PAGE                                                             # the page itself is unchanged


# -- a real browser --------------------------------------------------------------------------------------------------------------------

PROBE = """<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<style>#styled{color:rgb(1, 2, 3);font-size:23px} pre{white-space:pre-wrap;word-break:break-all}</style></head><body>
<p id="styled">styled</p>
<img id="img" alt="" src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7">
<pre id="out">pending</pre>
<script>
const out = {ran: true, origin: String(self.origin)};   // self.origin is the document's security origin ("null" when opaque); location.origin only echoes the URL
try { out.cookie = "read:" + document.cookie; } catch (e) { out.cookie = "threw:" + e.name; }
try { out.storage = "read:" + typeof localStorage.getItem("x"); } catch (e) { out.storage = "threw:" + e.name; }
const violations = [];
document.addEventListener("securitypolicyviolation", (e) => violations.push(e.violatedDirective + " " + e.blockedURI));
const tries = [["same-origin api", () => fetch("/api/config")],
               ["absolute api", () => fetch(location.href.replace(/\\/mockup\\/.*/, "/api/config"))],
               ["credentialed api", () => fetch("/api/config", {credentials: "include"})],
               ["other site", () => fetch("https://example.invalid/x")],
               ["xhr", () => new Promise((ok, no) => { const x = new XMLHttpRequest(); x.open("GET", "/api/config");
                                                        x.onload = ok; x.onerror = () => no(new Error("xhr blocked")); x.send(); })],
               ["websocket", () => new Promise((ok, no) => { const w = new WebSocket("ws://127.0.0.1:1/x"); w.onopen = ok; w.onerror = () => no(new Error("ws blocked")); })],
               ["beacon", () => new Promise((ok, no) => {   // sendBeacon may answer "queued" and be refused afterwards: the policy-violation report is the proof
                   if (!navigator.sendBeacon("/api/read", "{}")) return no(new Error("beacon blocked"));
                   setTimeout(() => (violations.some((v) => v.includes("/api/read")) ? no(new Error("beacon blocked")) : ok()), 1500); })]];
out.reach = {};
out.violations = violations;
Promise.all(tries.map(([k, f]) => Promise.resolve().then(f).then(() => { out.reach[k] = "REACHED"; }, (e) => { out.reach[k] = "blocked"; })))
  .then(() => { document.getElementById("out").textContent = JSON.stringify(out); document.title = "done"; });
</script></body></html>"""


def wait_for(browser, expr, secs=20):
    end = time.time() + secs
    last = None
    while time.time() < end:
        try:
            last = browser.evaluate(expr)
        except RuntimeError as e:
            last = str(e)
        if last:
            return last
        time.sleep(0.1)
    raise AssertionError(f"the page never reached {expr!r}: {last!r}")


def test_in_a_real_browser_the_pages_script_runs_but_cannot_reach_sala(served, browser):
    import json

    root = served["settings"].mockups_dir
    root.mkdir(parents=True, mode=0o700, exist_ok=True)
    store(root, 1, PROBE)
    browser.open(served["url"] + "/mockup/1", dark=False)
    wait_for(browser, "document.title === 'done'")
    out = json.loads(browser.evaluate("document.getElementById('out').textContent"))
    assert out["ran"] is True                                        # the inline script ran
    assert out["origin"] == "null"                                   # an opaque origin: not sala's
    assert out["cookie"].startswith("threw:SecurityError"), out      # no cookie to read
    assert out["storage"].startswith("threw:SecurityError"), out     # no storage either
    assert out["reach"] and set(out["reach"].values()) == {"blocked"}, out["reach"]   # nothing out: no sala API, no other site, no socket
    # inline style applied, data: image decoded, served as UTF-8
    assert browser.evaluate("getComputedStyle(document.getElementById('styled')).color") == "rgb(1, 2, 3)"
    assert browser.evaluate("getComputedStyle(document.getElementById('styled')).fontSize") == "23px"
    assert browser.evaluate("document.getElementById('img').naturalWidth") == 1
    assert browser.evaluate("document.characterSet") == "UTF-8"
    assert browser.evaluate("document.contentType") == "text/html"


def test_in_a_real_browser_a_phone_gets_the_pages_own_width(served, browser):
    root = served["settings"].mockups_dir
    root.mkdir(parents=True, mode=0o700, exist_ok=True)
    store(root, 1, PROBE)
    browser.open(served["url"] + "/mockup/1", dark=False)       # the fixture's viewport is a phone: 390 px, mobile
    wait_for(browser, "document.title === 'done'")
    assert browser.evaluate("window.innerWidth") == 390 and browser.evaluate("document.documentElement.scrollWidth") <= 390


@pytest.mark.parametrize("page", [
    PROBE,
    '<!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"></head>'
    '<body style="display:flex;margin:0"><div style="flex:1">a page that lays its body out as a flex row</div></body></html>',
    "<p>a page with no head, no body and no viewport meta</p>",
])
def test_in_a_real_browser_the_back_link_is_tappable_and_does_not_widen_the_page(served, browser, page):
    root = served["settings"].mockups_dir
    root.mkdir(parents=True, mode=0o700, exist_ok=True)
    store(root, 1, page)
    browser.open(served["url"] + "/mockup/1", dark=False)
    wait_for(browser, "document.readyState === 'complete'")
    if 'name="viewport"' in page:
        assert browser.evaluate("window.innerWidth") == 390          # a page with the meta is laid out at the phone's width
    layout = browser.evaluate("document.documentElement.clientWidth")   # without the meta the browser picks its own layout width (980): the page's doing
    box = browser.evaluate("(() => { const r = document.querySelector('[data-sala-back] a').getBoundingClientRect(); return [r.top, r.left, r.width, r.height]; })()")
    assert box[3] >= 44 and box[0] >= 0 and box[1] >= 0 and box[1] + box[2] <= layout, box
    assert browser.evaluate("document.documentElement.scrollWidth") <= layout     # nothing scrolls sideways
    assert browser.evaluate("document.querySelector('[data-sala-back] a').href") == served["url"] + "/chat"


def test_in_a_real_browser_the_site_itself_is_unaffected_by_the_sandbox(served, browser):
    # the sandbox is the mockup's: the page at / still reads its own cookies and API as before
    browser.open(served["url"] + "/", dark=False)
    wait_for(browser, "document.readyState === 'complete'")
    assert browser.evaluate("self.origin") != "null"
    assert browser.evaluate("(async () => (await fetch('/api/config')).status)()") == 200


@pytest.mark.parametrize("dark", [False, True])
def test_in_a_real_browser_the_history_icon_shares_the_back_row_and_its_list_covers_nothing_at_a_phone_width(served, browser, dark):
    import json

    root = served["settings"].mockups_dir
    root.mkdir(parents=True, mode=0o700, exist_ok=True)
    store(root, 1, PROBE)
    store_version(root, 1, V_OLD)
    store_version(root, 1, V_NEW)
    browser.open(served["url"] + "/mockup/1", dark=dark)
    wait_for(browser, "document.readyState === 'complete'")
    assert browser.evaluate("window.innerWidth") == 390
    geo = "(() => { const r = (s) => document.querySelector(s).getBoundingClientRect(); return JSON.stringify({" \
          "bar: r('[data-sala-back]'), back: r('[data-sala-back] > a'), icon: r('[data-sala-versions] summary'), body: r('#styled')," \
          "rows: [...document.querySelectorAll('[data-sala-versions] ol a')].map((a) => a.getBoundingClientRect())," \
          "sw: document.documentElement.scrollWidth}); })()"
    hit = "(() => { const r = document.querySelector(%r).getBoundingClientRect();" \
          "return document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2).closest('a, summary') === document.querySelector(%r); })()"
    before = json.loads(browser.evaluate(geo))
    bar, back, icon = before["bar"], before["back"], before["icon"]
    assert abs(bar["height"] - 44) <= 0.5, before                                            # one row
    assert abs(icon["top"] - bar["top"]) <= 0.5 and abs(back["top"] - bar["top"]) <= 0.5, before
    assert icon["height"] >= 44 and icon["width"] >= 44 and back["height"] >= 44, before
    assert back["right"] <= icon["left"] + 0.5 and abs(icon["right"] - bar["right"]) <= 0.5, before   # side by side, the icon at the right end
    assert icon["right"] <= 390 and before["sw"] <= 390, before
    for sel in ["[data-sala-back] > a", "[data-sala-versions] summary"]:
        assert browser.evaluate(hit % (sel, sel)) is True, sel                               # a tap on each reaches it
    browser.evaluate("document.querySelector('[data-sala-versions] summary').click()")
    wait_for(browser, "document.querySelector('[data-sala-versions]').open === true")
    opened = json.loads(browser.evaluate(geo))
    first, second = opened["rows"]
    assert first["height"] >= 44 and second["height"] >= 44, opened
    assert first["top"] >= opened["back"]["bottom"] - 0.5 and first["top"] >= opened["icon"]["bottom"] - 0.5, opened   # below the row
    assert second["top"] >= first["bottom"] - 0.5, opened
    assert opened["body"]["top"] >= opened["bar"]["bottom"] - 0.5 and opened["bar"]["bottom"] >= second["bottom"] - 0.5, opened   # in the flow
    assert max(first["right"], second["right"]) <= 390 and opened["sw"] <= 390, opened
    texts = browser.evaluate("[...document.querySelectorAll('[data-sala-versions] ol a')].map((a) => a.textContent)")
    assert texts == ["Until Fri Nov 27th 23:27 KST", "Until Tue Oct 27th 14:07 KST"]
    assert browser.evaluate("[...document.querySelectorAll('[data-sala-versions] ol a')].every((a) => a.scrollWidth <= a.clientWidth)")   # no label is cut
    browser.evaluate("document.querySelector('[data-sala-versions] ol a').click()")                  # the newest version
    wait_for(browser, "location.pathname.endsWith('/versions/" + V_NEW + "') && document.readyState === 'complete'")
    assert browser.evaluate("document.querySelector('[data-sala-when]').textContent") == "Until Fri Nov 27th 23:27 KST"
    assert browser.evaluate("document.querySelector('[data-sala-back] a').href") == served["url"] + "/mockup/1"
    assert browser.evaluate("document.querySelector('[data-sala-versions]')") is None                # no history inside a version
    row = json.loads(browser.evaluate(
        "(() => { const q = (s) => document.querySelector(s); const a = q('[data-sala-back] > a'); const r = (el) => el.getBoundingClientRect();"
        "return JSON.stringify({bar: r(q('[data-sala-back]')), link: r(a), when: r(q('[data-sala-when]')), whole: a.scrollWidth <= a.clientWidth,"
        "pad: getComputedStyle(q('[data-sala-when]')).paddingRight, sw: document.documentElement.scrollWidth}); })()"))
    bar, link, when = row["bar"], row["link"], row["when"]
    assert abs(bar["height"] - 44) <= 0.5 and abs(link["height"] - 44) <= 0.5 and abs(when["height"] - 44) <= 0.5, row   # one row
    assert abs(link["top"] - bar["top"]) <= 0.5 and abs(when["top"] - bar["top"]) <= 0.5, row
    assert abs(link["left"] - bar["left"]) <= 0.5 and abs(when["right"] - bar["right"]) <= 0.5 and row["pad"] == "16px", row
    assert link["right"] <= when["left"] + 0.5 and when["width"] > 0, row                           # side by side, no overlap
    assert row["whole"] is True and when["right"] <= 390 and row["sw"] <= 390, row                  # the link is never cut, nothing sideways
    browser.evaluate("document.querySelector('[data-sala-back] a').click()")
    wait_for(browser, "location.pathname.endsWith('/mockup/1')")


@pytest.mark.parametrize("dark", [False, True])
def test_in_a_real_browser_the_return_button_goes_back_when_there_is_history(served, browser, dark):
    root = served["settings"].mockups_dir
    root.mkdir(parents=True, mode=0o700, exist_ok=True)
    store(root, 1, PROBE)
    browser.open(served["url"] + "/", dark=dark)
    wait_for(browser, "document.readyState === 'complete'")
    browser.evaluate("location.href = '/mockup/1'")
    wait_for(browser, "location.pathname === '/mockup/1' && document.readyState === 'complete'")
    box = browser.evaluate("(() => { const r = document.querySelector('[data-sala-return]').getBoundingClientRect();"
                           "return [r.top, r.left, r.width, r.height, document.querySelector('[data-sala-return]').title]; })()")
    assert box[2] >= 44 and box[3] >= 44 and box[1] >= 0 and box[0] >= 0 and box[4], box
    assert browser.evaluate("(() => { const r = document.querySelector('[data-sala-return]').getBoundingClientRect();"
                            "return document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2).closest('button') !== null; })()")
    assert browser.evaluate("document.documentElement.scrollWidth") <= 390
    browser.evaluate("document.querySelector('[data-sala-return]').click()")
    wait_for(browser, "location.pathname === '/overview'")                # history.back(): the page the reader came from ('/' lands on /overview)


@pytest.mark.parametrize("path", ["/mockup/1", "/mockup/1/versions/" + V_OLD])
def test_in_a_real_browser_with_no_history_the_return_button_tries_to_close_then_opens_the_home_page(served, browser, path):
    root = served["settings"].mockups_dir
    root.mkdir(parents=True, mode=0o700, exist_ok=True)
    store(root, 1, PROBE)
    store_version(root, 1, V_OLD)
    browser.open(served["url"] + path, dark=False)
    wait_for(browser, "document.readyState === 'complete'")
    # the harness's tab already has an entry behind it, so it is made to look like a new window (one entry); the test tab must also stay open to be read
    browser.evaluate("Object.defineProperty(History.prototype, 'length', {get: () => 1}); window.close = () => {}")
    browser.evaluate("document.querySelector('[data-sala-return]').click()")
    wait_for(browser, "['/', '/overview'].includes(location.pathname)")   # sala's home page, the session list ('/' goes on to /overview)
    assert browser.evaluate("self.origin") != "null"                      # the home page is sala itself, outside the sandbox
