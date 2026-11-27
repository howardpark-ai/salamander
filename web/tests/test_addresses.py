"""The pages' addresses: each view of the main page has a path of its own (/s/<name>, /overview, …), and no address of sala's holds
a "#" (static/address.js; web/README.md, *Addresses*). The server's side (app.py): every view's path is served by the same handler,
under the same checks, as "/"; and the script's own rules, run under node. In a browser: test_addresses_ui.py.

What is held:
  - a view's path answers as "/" does: the same page and headers, the same methods, the same redirect of ?arg=, the same record of
    the visit; only the page's <base> differs, which climbs back to the app's root from a two-segment path, under any path prefix;
  - a path that is no view is a 404, a session's with no name included;
  - /chat and /sessions lead to a view's path, relative to wherever the app is mounted;
  - the links in the served page (the help link among them) are paths the server answers;
  - the script turns a view into its path and back, and rewrites a link of before (/#s=<name>) to the path, which the server never
    needs to see: a browser keeps the part after "#" to itself.
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
from urllib.parse import urljoin

import pytest
from starlette.testclient import TestClient

from sala_web import app as A
from sala_web.config import Settings

NODE = shutil.which("node")
needs_node = pytest.mark.skipif(not NODE, reason="node is not installed")
ADDRESS_JS = A.STATIC / "address.js"

# a view's path -> the <base> its page carries: the way back to the app's root
PLAIN = {"/overview": "./", "/schedules": "./", "/machines": "./", "/usage": "./", "/new": "./", "/side": "./", "/search": "./",
         "/s/demo-main": "../", "/s/a%2Fb": "../", "/s/item%2338%3F": "../", "/s/a/b": "../../", "/lane/api": "../",
         "/lane/subscription-1": "../"}
QUERIED = {"/side?item%2338": "./", "/side?from:demo-main": "./", "/search?q=zebra&hours=24": "./", "/s/demo-main?debug=timing": "../"}
VIEWS = {**PLAIN, **QUERIED}
BASE = re.compile(r'<base href="([^"]*)">')


@pytest.fixture
def client(tmp_path):
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True)
    (claude / "projects").mkdir()
    return TestClient(A.create_app(Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude,
                                            tmux_socket_name="salaweb-pytest-unused", roles_cmd=["false"])))


@pytest.fixture
def visits(monkeypatch):
    """The paths whose visit was recorded (`sala where`), nothing run."""
    seen: list[str] = []
    monkeypatch.setattr(A.WS, "note", lambda request, settings: seen.append(request.url.path))
    return seen


def headers(r) -> dict:
    return {k: v for k, v in r.headers.items() if k not in ("content-length", "date")}


# ── every view's path is "/" ─────────────────────────────────────────────────
@pytest.mark.parametrize("path", VIEWS)
def test_a_view_s_path_serves_the_same_page_as_the_root_and_only_its_base_differs(client, visits, path):
    root = client.get("/", follow_redirects=False)
    r = client.get(path, follow_redirects=False)
    assert r.status_code == root.status_code == 200
    assert headers(r) == headers(root)
    assert BASE.findall(root.text) == ["./"] and BASE.findall(r.text) == [VIEWS[path]]
    assert BASE.sub('<base href="./">', r.text) == root.text and "{{" not in r.text
    assert len(visits) == 2, "the visit is recorded as the root's is"


@pytest.mark.parametrize("path", VIEWS)
def test_the_base_leads_back_to_the_app_s_root_under_any_path_prefix(path):
    for root in ("https://sala.example.test/", "https://sala.example.test/some/prefix/"):
        assert urljoin(urljoin(root + path[1:], VIEWS[path]), "static/app.js") == root + "static/app.js"


@pytest.mark.parametrize("path", PLAIN)
def test_a_view_s_path_takes_the_methods_the_root_takes_and_no_other(client, visits, path):
    for method in ("HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"):
        want = client.request(method, "/", follow_redirects=False)
        got = client.request(method, path, follow_redirects=False)
        assert got.status_code == want.status_code, method
        assert got.headers.get("allow") == want.headers.get("allow"), method


@pytest.mark.parametrize("path", PLAIN)
def test_an_old_terminal_query_redirects_from_a_view_s_path_as_from_the_root(client, visits, path):
    want = client.get("/?arg=demo", follow_redirects=False)
    got = client.get(path + "?arg=demo", follow_redirects=False)
    assert (got.status_code, got.headers["location"]) == (want.status_code, want.headers["location"]) == (302, "/terminal?arg=demo")
    assert visits == []


@pytest.mark.parametrize("path", ["/s", "/s/", "/lane", "/lane/", "/lane/a/b", "/overview/x", "/new/x", "/side/x", "/search/x",
                                  "/Overview", "/nothing", "/chat/x", "/static/s/demo"])
def test_a_path_that_is_no_view_is_not_found(client, visits, path):
    assert client.get(path).status_code == 404
    assert visits == []


# ── the redirects ────────────────────────────────────────────────────────────
@pytest.mark.parametrize("session, location", [("demo-chat", "./s/demo-chat"), (None, "./")])
def test_chat_leads_to_the_chat_session_s_path_or_the_root(client, visits, monkeypatch, session, location):
    if session:
        monkeypatch.setenv("SALA_CHAT_SESSION", session)
    else:
        monkeypatch.delenv("SALA_CHAT_SESSION", raising=False)
    r = client.get("/chat", follow_redirects=False)
    assert (r.status_code, r.headers["location"]) == (302, location)
    assert urljoin("https://sala.example.test/prefix/chat", location) == "https://sala.example.test/prefix/" + location[2:]
    assert client.get("/chat").status_code == 200


def test_the_old_overview_page_leads_to_the_overview_s_path(client, visits):
    r = client.get("/sessions", follow_redirects=False)
    assert (r.status_code, r.headers["location"]) == (302, "./overview")
    assert client.get("/sessions").url.path == "/overview"


# ── the served page ──────────────────────────────────────────────────────────
def test_the_help_link_is_the_help_session_s_path_and_is_absent_with_none_set(client, visits, monkeypatch):
    monkeypatch.setenv("SALA_HELP_SESSION", "help-session")
    for path in ("/", "/overview", "/s/demo-main"):
        assert re.search(r'<a id="sp-help"[^>]* href="s/help-session"', client.get(path).text), path
    monkeypatch.delenv("SALA_HELP_SESSION")
    assert 'id="sp-help"' not in client.get("/overview").text


def test_every_page_link_in_the_served_page_is_a_path_the_server_answers(client, visits, monkeypatch):
    monkeypatch.setenv("SALA_HELP_SESSION", "help-session")
    links = [h for h in re.findall(r'<a\s[^>]*?href="([^"]*)"', client.get("/").text) if not h.startswith(("http:", "https:"))]
    assert {"overview", "schedules", "machines", "usage", "new", "side", "s/help-session"} <= set(links), links
    for href in links:
        assert not href.startswith(("#", "/")), href
        assert client.get("/" + href).status_code == 200, href


def test_the_base_comes_before_every_address_in_the_page_and_the_script_before_what_reads_it(client, monkeypatch):
    monkeypatch.setenv("SALA_CHAT_SESSION", "demo-chat")
    page = client.get("/s/demo-chat").text
    base = BASE.search(page).start()
    assert base < min(m.start() for m in re.finditer(r'(?:src|href)="(?!\.\./")', page) if m.start() != base + len("<base "))
    at = [page.index(f'<script src="static/{n}.js?v=') for n in ("address", "colortool-sala", "signin", "chatboot", "app")]
    assert base < at[0] and at == sorted(at), at
    r = client.get("/static/address.js")
    assert r.status_code == 200 and "javascript" in r.headers["content-type"]


# ── the script's own rules ───────────────────────────────────────────────────
# `load(href, base)`: address.js run for a page at `href` whose <base> reads `base`, with the parts of the browser it uses
HARNESS = """
const vm = require("vm"), code = require("fs").readFileSync(%s, "utf8");
const load = (href, base = "./") => {
  let attr = base; const location = new URL(href), replaced = [];
  const tag = { get href() { return new URL(attr, location.href).href; }, set href(v) { attr = v; } };
  const document = { querySelector: () => tag, get baseURI() { return tag.href; } };
  const history = { state: { kept: 1 }, replaceState: (state, _, url) => { replaced.push([state, url]); location.href = new URL(url, tag.href).href; } };
  const window = {};
  vm.runInNewContext(code, { window, document, location, history, URL, Map });
  return { A: window.SalaAddress, location, replaced };
};
"""

ROOTS = ["https://sala.example.test/", "https://sala.example.test/some/prefix/"]
# a view form -> its path under the app's root
FORMS = [("#sessions", "overview"), ("#schedules", "schedules"), ("#machines", "machines"), ("#usage", "usage"), ("#new", "new"),
         ("#s=demo-main", "s/demo-main"), ("#s=a%2Fb", "s/a%2Fb"), ("#s=item%2338%3F", "s/item%2338%3F"),
         ("#lane=subscription-1", "lane/subscription-1"), ("#search", "search"), ("#search?q=zebra&hours=24", "search?q=zebra&hours=24"),
         ("#side=", "side"), ("#side=from:demo-main", "side?from:demo-main"), ("#side=item%2338", "side?item%2338")]


def run_node(body: str):
    script = HARNESS % json.dumps(str(ADDRESS_JS)) + body
    r = subprocess.run([NODE, "-e", script], capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, r.stderr
    return json.loads(r.stdout)


def up(path: str) -> str:
    """The <base> the server writes for a path under the root."""
    return "../" if "/" in path.split("?")[0] else "./"


@needs_node
@pytest.mark.parametrize("root", ROOTS, ids=["host-root", "path-prefix"])
def test_a_view_becomes_its_path_and_the_path_is_read_back_as_the_view(root):
    cases = [[view, path, up(path)] for view, path in FORMS + [("", "")]]
    got = run_node(f"""const root = {json.dumps(root)};
      console.log(JSON.stringify({json.dumps(cases)}.map(([view, path, base]) => {{
        const from = load(root).A.url(view), at = load(root + path, base);
        return [view, from, at.A.here(), at.replaced.length, at.A.url("#usage")]; }})));""")
    for (view, path, _), row in zip(cases, got, strict=True):
        assert row == [view, root + path, view, 0, root + "usage"], row


@needs_node
@pytest.mark.parametrize("root", ROOTS, ids=["host-root", "path-prefix"])
def test_a_link_of_before_is_rewritten_to_the_view_s_path_at_the_load(root):
    got = run_node(f"""const root = {json.dumps(root)};
      console.log(JSON.stringify({json.dumps(FORMS)}.map(([view]) => {{
        const at = load(root + view); return [at.replaced, at.A.here()]; }})));""")
    for (view, path), (replaced, here) in zip(FORMS, got, strict=True):
        assert replaced == [[{"kept": 1}, root + path]] and here == view, (view, replaced, here)


@needs_node
def test_the_less_usual_addresses():
    root = ROOTS[0]
    # [the address loaded, its <base>] -> [the address afterwards, the view]
    cases = [
        # an item's id written with its bare "#", in a link of before and typed into the path form
        ("#side=item#38", "./", "side?item%2338", "#side=item%2338"),
        ("side?item#38", "./", "side?item#38", "#side=item#38"),
        # the page's own query goes along with a view that has none of its own; a view with one carries only its own
        ("?debug=timing#usage", "./", "usage?debug=timing", "#usage"),
        ("?debug=timing#search?q=a", "./", "search?q=a", "#search?q=a"),
        # a "#..." on a view's path wins over the path
        ("s/demo#sessions", "../", "overview", "#sessions"),
        # what names no view is left alone
        ("#top", "./", "#top", ""),
        ("overview#top", "./", "overview#top", "#sessions"),
    ]
    got = run_node(f"""const root = {json.dumps(root)};
      console.log(JSON.stringify({json.dumps(cases)}.map(([from, base]) => {{ const at = load(root + from, base); return [at.location.href, at.A.here()]; }})));""")
    for (start, _, after, view), row in zip(cases, got, strict=True):
        assert row == [root + after, view], (start, row)


@needs_node
def test_an_address_that_is_no_view_of_this_app_is_not_read_as_one():
    root = ROOTS[1]
    others = [root + p for p in ("api/config", "terminal", "static/app.js", "mockup/1", "s/", "lane/a/b", "overview/x", "overview?x=1")]
    others += ["https://sala.example.test/overview", "https://sala.example.test/s/demo"]   # outside the prefix
    got = run_node(f"""const page = load({json.dumps(root)});
      console.log(JSON.stringify({json.dumps(others)}.map((u) => page.A.read(new URL(u)))));""")
    assert got == [None] * len(others), list(zip(others, got))
