"""Mockup pages: GET /mockup/<n> serves what `sala mockup add` stored, in a sandbox (mockup.py, README *Mockup pages*).

The route tests drive the app in process (starlette's TestClient). The last two tests open a served page in a real headless Chromium (the `served`
and `browser` fixtures of conftest.py; skipped where there is none) and let the page's own script try to reach sala's API and cookies.
"""

import os
import re
import time
from pathlib import Path

import pytest
from starlette.testclient import TestClient

from sala_web import mockup as MK
from sala_web.app import create_app
from sala_web.config import Settings

STATIC = Path(__file__).resolve().parent.parent / "src" / "sala_web" / "static"
DOCS = Path(__file__).resolve().parent.parent.parent / "docs"

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
    assert r.content == PAGE.encode("utf-8")        # served as stored: no rewriting, the viewport meta and the Google Fonts link included
    check_sandbox_headers(r)
    assert r.headers["cache-control"] == "private, no-cache"


def test_the_viewport_meta_a_phone_needs_reaches_the_reader_unchanged(env):
    store(env["root"], 2)
    assert 'name="viewport" content="width=device-width, initial-scale=1"' in env["client"].get("/mockup/2").text


def test_numbers_are_the_files_and_the_largest_works(env):
    store(env["root"], 9999999999, "<p>big number</p>")
    assert env["client"].get("/mockup/9999999999").text == "<p>big number</p>"


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


# -- the 404s ------------------------------------------------------------------------------------------------------------------------


@pytest.mark.parametrize("path", ["/mockup/7", "/mockup/0", "/mockup/01", "/mockup/007", "/mockup/abc", "/mockup/-1", "/mockup/1.html",
                                  "/mockup/1/", "/mockup/1/x", "/mockup/1/../2", "/mockup/%2e%2e%2fcounter", "/mockup/counter", "/mockup/.lock",
                                  "/mockup/", "/mockup", "/mockup/99999999999", "/mockup/1%00"])
def test_an_unknown_or_malformed_address_is_a_404_that_still_carries_the_sandbox_headers(env, path):
    store(env["root"], 1)
    (env["root"] / "counter").write_text("1\n")
    r = env["client"].get(path)
    assert r.status_code == 404, path
    assert r.text == "no such mockup"
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


def test_the_v2_prefix_serves_the_same_page_with_the_same_headers(env):
    store(env["root"], 1)
    r = env["client"].get("/v2/mockup/1")
    assert r.status_code == 200 and r.content == PAGE.encode("utf-8")
    check_sandbox_headers(r)


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


def test_in_a_real_browser_the_site_itself_is_unaffected_by_the_sandbox(served, browser):
    # the sandbox is the mockup's: the page at / still reads its own cookies and API as before
    browser.open(served["url"] + "/", dark=False)
    wait_for(browser, "document.readyState === 'complete'")
    assert browser.evaluate("self.origin") != "null"
    assert browser.evaluate("(async () => (await fetch('/api/config')).status)()") == 200
