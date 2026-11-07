"""Images a reply names in its markdown: ![caption](/abs/path/mock.png) or ![caption](~/path/mock.png).

A session shows the owner an image by writing a markdown image whose destination is a file on this machine. The chat draws
it inline at that spot in the reply, through GET /api/md-image/<sid>/<uuid>/<i>/<n>: the URL names a place in the transcript
(the line, the text block, the n-th local image of that text), never a path, so the server serves a path only when it appears
in a markdown image of that session's assistant text, and then only under the rules of a SendUserFile image (sentimages.py:
png, jpeg, gif or webp by extension and first bytes, inside the allowed roots, nothing hidden or secret-named, symlinks
resolved before the check, a size cap).

What a wrong answer costs: an image that does not draw (the owner is shown a path instead of the mock-up), a request that reads
a file no reply named (any file under the home directory by URL), a link out of the roots followed, a broken-image icon where a
refusal should say why, a page that scrolls sideways on a phone, an http image that stopped working because a local path now has
its own handling, or an image in a code block drawn as if it were part of the reply.

The parser, the extractor and the route run without a browser; the page runs in a headless Chromium when one is installed
(conftest.py: `served`, `browser`), at 1280 px and at 390 px, else skipped. Every temp folder is made by a fixture that locks it
(flock) while the test runs and removes it afterwards, pass or fail; the local web server for the http image is stopped in a `finally`.
"""

from __future__ import annotations

import fcntl
import json
import os
import shutil
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest
from starlette.testclient import TestClient

from conftest import NAME, SID, transcript_file
from sala_web import sentimages as SI
from sala_web import transcript as TR
from sala_web.app import create_app
from sala_web.config import Settings
from test_sent_images import GIF, JPG, png

UUID = "00000000-0000-4000-8000-0000000000c1"
USER_UUID = "00000000-0000-4000-8000-0000000000c2"

OUTSIDE = "outside the folders that can be shown"
HIDDEN = "inside a hidden or secret-named folder"
NOT_IMAGE = "not a png, jpeg, gif or webp image"
GONE = "file not found"


class Folder:
    """A temp folder made, locked while the test runs, and removed at the end."""

    def __init__(self, prefix: str, parent: str | None = None):
        self.path = Path(tempfile.mkdtemp(prefix=prefix, dir=parent))
        self.fd = os.open(self.path, os.O_RDONLY)
        fcntl.flock(self.fd, fcntl.LOCK_EX)  # systemd-tmpfiles ageing honours a lock on the folder

    def close(self) -> None:
        os.close(self.fd)
        shutil.rmtree(self.path, ignore_errors=True)


def put(path: Path, data: bytes) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return path


@pytest.fixture
def root(monkeypatch):
    """The only place a reply's image may be read from in a test, laid out as the cases need; HOME points at it, so ~/ means it.
    List it before `served` (the app reads the setting when it is built)."""
    top = Folder("sala-mdimg-")
    try:
        r = top.path / "home"
        outside = top.path / "out"
        put(r / "shots" / "mock.png", png(640, 480))
        put(r / "shots" / "photo.jpg", JPG)
        put(r / "shots" / "anim.gif", GIF)
        put(r / ".private" / "pic.png", png())          # under a dot-folder
        put(r / "notes" / "readme.txt", b"just text\n")  # not an image
        put(r / "notes" / "fake.png", b"#!/bin/sh\necho hi\n")  # an image name over other bytes
        put(r / "secrets" / "pic.png", png())
        put(outside / "elsewhere.png", png())
        (r / "shots" / "link.png").symlink_to(outside / "elsewhere.png")  # a link out of the roots
        (r / "shots" / "dirlink").symlink_to(outside)
        monkeypatch.setenv("SALA_WEB_IMAGE_ROOTS", str(r))
        monkeypatch.setenv("HOME", str(r))
        yield r
    finally:
        top.close()


def outside_of(r: Path) -> Path:
    """The folder next to the root that is not an allowed place."""
    return r.parent / "out"


def assistant_line(text_blocks: list, cwd: str, uuid: str = UUID, kind: str = "assistant") -> str:
    content = [{"type": "text", "text": t} if isinstance(t, str) else t for t in text_blocks]
    return json.dumps({"type": kind, "uuid": uuid, "timestamp": "2026-10-20T03:00:00.000Z", "cwd": cwd,
                       "message": {"role": kind, "model": "claude-opus-5-5", "content": content}}) + "\n"


def case_text(r: Path, web: str = "") -> str:
    """One reply holding every case: an image that is served, then each refusal, then an http image."""
    return "\n\n".join([
        "Here is the mock-up:",
        f"![mock](<{r}/shots/mock.png>)",
        f"![hidden one]({r}/.private/pic.png)",
        f"![a text file]({r}/notes/readme.txt)",
        f"![missing one]({r}/shots/gone.png)",
        f"![linked out]({r}/shots/link.png)",
        f"![web one]({web or 'http://127.0.0.1:9/none.png'})",
        "Done.",
    ])


# ---------- the extractor and the parser ----------


def test_the_extractor_finds_local_images_outside_code_only():
    text = "\n".join([
        "![a](/home/x/a.png) and ![b](~/b.jpg \"title\") and ![c](<~/my pics/c.png>) and ![d](/tmp/e(1).png)",
        "![web](http://example.test/w.png) ![data](data:image/png;base64,AAAA) ![proto](//host/p.png) ![rel](shots/r.png)",
        "```",
        "![fenced](/home/x/fenced.png)",
        "```",
        "~~~sh",
        "![tilde](/home/x/tilde.png)",
        "~~~",
        "`![span](/home/x/span.png)` and ``![span2](/home/x/span2.png)``",
        "[a link](/home/x/link.png) and no image",
    ])
    assert SI.md_image_paths(text) == ["/home/x/a.png", "~/b.jpg", "~/my pics/c.png", "/tmp/e(1).png"]
    assert SI.md_image_paths("") == [] and SI.md_image_paths("no images here") == []


def test_the_parser_offers_a_url_per_local_image_never_a_server_path(root):
    line = json.loads(assistant_line([case_text(root)], str(root)))
    m = TR.parse_line(line, SID)
    (blk,) = m["blocks"]
    offered = blk["localImages"]
    assert [o["src"] for o in offered] == [f"{root}/shots/mock.png", f"{root}/.private/pic.png", f"{root}/notes/readme.txt",
                                           f"{root}/shots/gone.png", f"{root}/shots/link.png"]  # the http image is no local one
    assert [o["url"] for o in offered] == [f"api/md-image/{SID}/{UUID}/0/{n}" for n in range(5)]
    # a reply with no local image carries no key
    plain = TR.parse_line(json.loads(assistant_line(["![w](https://example.test/a.png)"], str(root))), SID)
    assert "localImages" not in plain["blocks"][0]
    # a user's text is never given one
    user = TR.parse_line(json.loads(assistant_line([f"![x]({root}/shots/mock.png)"], str(root), kind="user")), SID)
    assert all("localImages" not in b for b in user["blocks"])


def test_find_md_image_reads_the_named_place_in_the_transcript(tmp_path):
    p = tmp_path / "t.jsonl"
    p.write_text(assistant_line(["intro", "![a](/work/a.png) ![b](~/b.png)\n```\n![c](/work/c.png)\n```"], "/work")
                 + assistant_line(["![u](/work/u.png)"], "/work", uuid=USER_UUID, kind="user"))
    assert TR.find_md_image(p, UUID, 1, 0) == ("/work/a.png", "/work")
    assert TR.find_md_image(p, UUID, 1, 1) == ("~/b.png", "/work")
    assert TR.find_md_image(p, UUID, 1, 2) is None   # the fenced one is not an image of the reply
    assert TR.find_md_image(p, UUID, 0, 0) is None   # no image in that block
    assert TR.find_md_image(p, UUID, 5, 0) is None   # no such block
    assert TR.find_md_image(p, UUID, 1, -1) is None  # not Python's last one
    assert TR.find_md_image(p, USER_UUID, 0, 0) is None  # a user line names nothing
    assert TR.find_md_image(p, "00000000-0000-4000-8000-0000000000ff", 1, 0) is None


# ---------- the rules, with their reasons ----------


def test_check_image_serves_the_four_types_and_says_why_it_refuses(root):
    roots = [root]
    for name, mt in (("mock.png", "image/png"), ("photo.jpg", "image/jpeg"), ("anim.gif", "image/gif")):
        got = SI.check_image(str(root / "shots" / name), "", roots)
        assert isinstance(got, tuple) and got[0] == mt, name
    assert SI.check_image("~/shots/mock.png", "", roots)[0] == "image/png"  # ~ is HOME, which the fixture points at root
    assert SI.check_image(f"{root}/.private/pic.png", "", roots) == HIDDEN
    assert SI.check_image(f"{root}/secrets/pic.png", "", roots) == HIDDEN
    assert SI.check_image(f"{root}/notes/readme.txt", "", roots) == NOT_IMAGE
    assert SI.check_image(f"{root}/notes/fake.png", "", roots) == NOT_IMAGE        # a name over other bytes
    assert SI.check_image(f"{root}/shots/gone.png", "", roots) == GONE
    assert SI.check_image(f"{root}/shots/link.png", "", roots) == OUTSIDE          # a link out
    assert SI.check_image(f"{root}/shots/dirlink/elsewhere.png", "", roots) == OUTSIDE
    assert SI.check_image(f"{outside_of(root)}/elsewhere.png", "", roots) == OUTSIDE
    assert SI.check_image("/etc/hostname.png", "", roots) in (OUTSIDE, GONE)
    assert SI.check_image(f"{root}/shots/vector.svg", "", roots) == NOT_IMAGE
    big = put(root / "shots" / "big.png", png() + b"\x00" * 3000)
    assert SI.check_image(str(big), "", roots, max_bytes=100) == "file too large"
    # read_sent_image keeps its answer: the file or nothing
    assert SI.read_sent_image(str(root / "shots" / "mock.png"), "", roots) is not None
    assert SI.read_sent_image(f"{root}/.private/pic.png", "", roots) is None


def test_a_png_under_the_default_roots_is_served(monkeypatch):
    """The real check: the roots as shipped (the home directory and Claude Code's scratch directory)."""
    monkeypatch.delenv("SALA_WEB_IMAGE_ROOTS", raising=False)
    scratch = Path(f"/tmp/claude-{os.getuid()}")
    if not scratch.is_dir() or not os.access(scratch, os.W_OK):
        pytest.skip(f"{scratch} is not there to write into")
    folder = Folder("sala-mdimg-real-", parent=str(scratch))
    try:
        p = put(folder.path / "mock.png", png())
        roots = Settings().image_roots
        assert SI.check_image(str(p), "", roots)[0] == "image/png"
    finally:
        folder.close()


# ---------- the route ----------


@pytest.fixture
def client(root, tmp_path):
    claude = tmp_path / "claude"
    proj = claude / "projects" / TR.project_slug(str(root))
    proj.mkdir(parents=True)
    # block 0 is the reply with the cases; block 1 is another reply's text holding a ~ path and an image inside code
    (proj / f"{SID}.jsonl").write_text(
        assistant_line([case_text(root), f"![home](~/shots/photo.jpg)\n\n```\n![fenced]({root}/shots/mock.png)\n```"], str(root))
        + assistant_line([f"![from the user]({root}/shots/mock.png)"], str(root), uuid=USER_UUID, kind="user"))
    settings = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude,
                        tmux_socket_name="salaweb-pytest-none", roles_cmd=["false"], sala_models=tmp_path / "none.tsv",
                        admin_key=tmp_path / "none-key")
    return TestClient(create_app(settings))


def md_url(i: int, n: int, uuid: str = UUID) -> str:
    return f"/api/md-image/{SID}/{uuid}/{i}/{n}"


def test_route_serves_the_named_image_with_safe_headers(client):
    r = client.get(md_url(0, 0))
    assert r.status_code == 200 and r.headers["content-type"] == "image/png" and r.content.startswith(b"\x89PNG")
    assert r.headers["x-content-type-options"] == "nosniff"
    assert "sandbox" in r.headers["content-security-policy"] and "private" in r.headers["cache-control"]
    r = client.get(md_url(1, 0))  # ~/shots/photo.jpg
    assert r.status_code == 200 and r.headers["content-type"] == "image/jpeg"


def test_route_refuses_each_unsafe_image_and_says_why(client):
    for n, why in ((1, HIDDEN), (2, NOT_IMAGE), (3, GONE), (4, OUTSIDE)):
        r = client.get(md_url(0, n))
        assert r.status_code == 404 and r.json()["error"] == why, (n, r.text)
        assert r.headers["content-type"].startswith("application/json")  # never image bytes


def test_route_serves_nothing_a_reply_does_not_name(client, root):
    named = "the reply does not name this image"
    # a place with no local image: past the last one, a text with none, a missing block, a negative number
    assert client.get(md_url(0, 5)).json()["error"] == named  # the http image is no local one
    assert client.get(md_url(1, 1)).json()["error"] == named  # the fenced one is code, not an image
    assert client.get(md_url(9, 0)).status_code == 404
    assert client.get(md_url(0, -1)).status_code == 404
    assert client.get(md_url(0, 0, uuid="00000000-0000-4000-8000-0000000000ff")).status_code == 404
    assert client.get(md_url(0, 0, uuid=USER_UUID)).status_code == 404      # a user line names nothing
    assert client.get(f"/api/md-image/{'bb' * 4}-0000-4000-8000-000000000001/{UUID}/0/0").status_code == 404  # no transcript
    # a request that carries a path of its own: there is no parameter for it, and the route ignores a query
    for extra in (f"?path={root}/notes/fake.png", f"?path=/etc/passwd", f"?file={root}/shots/photo.jpg&n=1"):
        r = client.get(md_url(0, 3) + extra)
        assert r.status_code == 404 and r.json()["error"] == GONE, extra
    assert client.get(f"/api/md-image/{SID}/{UUID}/0/{root}/shots/photo.jpg").status_code == 404
    assert client.get(f"/api/md-image/{SID}/{UUID}/0/%2e%2e%2fphoto.jpg").status_code == 404
    # a file under the root that no reply names is not reachable, whatever number is tried
    for n in range(-2, 40):
        r = client.get(md_url(0, n))
        assert not r.headers["content-type"].startswith("image/") or n in (0,), n


def test_route_follows_the_transcript_not_the_disk(client, root, tmp_path):
    """The reply is re-read on each request: a transcript that names a file outside the roots gets no image."""
    claude = tmp_path / "claude" / "projects" / TR.project_slug(str(root)) / f"{SID}.jsonl"
    for named in (f"{outside_of(root)}/elsewhere.png", "/etc/passwd.png", f"{root}/shots/../../etc/x.png", f"{root}/.private/pic.png"):
        claude.write_text(assistant_line([f"![x]({named})"], str(root)))
        assert client.get(md_url(0, 0)).status_code == 404, named


# ---------- the page ----------

PROBE = r"""
new Promise((res) => {
  const t0 = Date.now();
  (function poll() {
    if (document.querySelectorAll("#chat .md-local").length < __N__ && Date.now() - t0 < 15000) return setTimeout(poll, 100);
    const t1 = Date.now();
    (function wait() {
      const open = [...document.querySelectorAll("#chat .md-local")].filter((b) => {
        const i = b.querySelector("img.md-local-img");
        return i && !(i.complete && i.naturalWidth > 0);
      });
      const web = [...document.querySelectorAll("#chat .md img:not(.md-local-img)")].filter((i) => !i.complete);
      if ((open.length || web.length) && Date.now() - t1 < 10000) return setTimeout(wait, 100);
      setTimeout(() => {
        const boxes = [...document.querySelectorAll("#chat .md-local")].map((b) => {
          const img = b.querySelector("img"), a = b.querySelector("a");
          const r = img ? img.getBoundingClientRect() : { width: 0, height: 0, right: 0 };
          return { hasImg: !!img, natural: img && img.naturalWidth, w: r.width, h: r.height, right: r.right,
                   href: a && a.getAttribute("href"), target: a && a.getAttribute("target"), rel: a && a.getAttribute("rel"),
                   loading: img && img.getAttribute("loading"), text: b.textContent.trim(),
                   missing: (b.querySelector(".md-local-missing") || {}).textContent || null,
                   caption: (b.querySelector(".md-local-cap") || {}).textContent || null,
                   visible: !!b.offsetParent, msgVisible: !!b.closest(".msg").offsetParent };
        });
        const webs = [...document.querySelectorAll("#chat .md img:not(.md-local-img)")].map((i) => ({
          src: i.getAttribute("src"), natural: i.naturalWidth, inLocal: !!i.closest(".md-local") }));
        const broken = [...document.querySelectorAll("#chat .md img.md-local-img")].filter((i) => !(i.complete && i.naturalWidth > 0)).length;
        res({ width: innerWidth, scrollW: document.documentElement.scrollWidth, chatScroll: document.querySelector("#chat").scrollWidth,
              chatClient: document.querySelector("#chat").clientWidth, boxes, webs, broken,
              hideTools: document.body.classList.contains("hide-tools") });
      }, 400);  // an image that failed to load swaps itself for its reason in its error handler
    })();
  })();
})
"""


@pytest.fixture
def web_png():
    """A local web server holding a png at /w.png (the 'http image' case); stopped when the test ends."""
    data = png(120, 80)

    class H(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *a):
            pass

    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    try:
        yield f"http://127.0.0.1:{srv.server_address[1]}/w.png"
    finally:
        srv.shutdown()
        srv.server_close()
        t.join(timeout=10)


def opened(served, browser, root, web: str, width: int, height: int, mobile: bool):
    transcript_file(served).write_text(assistant_line([case_text(root, web)], str(root)))
    browser.open(f"{served['url']}/#s={NAME}")
    browser.send("Emulation.setDeviceMetricsOverride", {"width": width, "height": height, "deviceScaleFactor": 1, "mobile": mobile})
    return browser.evaluate(PROBE.replace("__N__", "5"))


@pytest.mark.parametrize("width,height,mobile", [(1280, 800, False), (390, 844, True)])
def test_the_reply_draws_the_image_inline_and_a_refusal_says_why(root, served, browser, web_png, width, height, mobile):
    got = opened(served, browser, root, web_png, width, height, mobile)
    where = json.dumps(got)
    assert got["width"] == width and got["scrollW"] <= width and got["chatScroll"] <= got["chatClient"], where  # no sideways scroll
    ok, hidden, txt, gone, link = got["boxes"]
    # the tool folds are hidden (the default), the image is not: it is in the reply's text
    assert got["hideTools"] and ok["msgVisible"] and ok["visible"], where
    assert ok["hasImg"] and ok["natural"] == 640 and 0 < ok["w"] <= width and ok["right"] <= width and ok["h"] > 40, where
    assert ok["loading"] == "lazy" and ok["href"] == f"api/md-image/{SID}/{UUID}/0/0", where
    assert ok["target"] == "_blank" and "noopener" in ok["rel"] and ok["caption"] == "mock", where  # tap to open it full size
    assert got["broken"] == 0, where  # no image left in the page that failed to load
    # each refusal is one muted line with its reason, the caption stays, and there is no image element to show a broken icon
    for box, caption, why in ((hidden, "hidden one", HIDDEN), (txt, "a text file", NOT_IMAGE), (gone, "missing one", GONE),
                              (link, "linked out", OUTSIDE)):
        assert not box["hasImg"] and box["missing"] == "image not shown: " + why and box["caption"] == caption, (box, where)
        assert box["visible"] and box["text"] == f"image not shown: {why}{caption}", (box, where)
    # the image sits at its spot: after the intro, before "Done."
    order = browser.evaluate("""[...document.querySelectorAll('#chat .md > *')].map((n) => n.querySelector('.md-local') ? 'img' : n.textContent.trim().slice(0, 12))""")
    assert order[0] == "Here is the " and order[-1] == "Done." and order.count("img") == 5, order


@pytest.mark.parametrize("width,height,mobile", [(1280, 800, False), (390, 844, True)])
def test_an_http_image_still_works_as_before(root, served, browser, web_png, width, height, mobile):
    got = opened(served, browser, root, web_png, width, height, mobile)
    assert len(got["webs"]) == 1, got
    (w,) = got["webs"]
    assert w["src"] == web_png and w["natural"] == 120 and not w["inLocal"], got  # drawn from its URL, by the page, untouched


def test_a_home_path_and_an_image_in_code_in_the_page(root, served, browser):
    transcript_file(served).write_text(assistant_line(
        ["![home](~/shots/mock.png)\n\n```\n![fenced](" + str(root) + "/shots/mock.png)\n```"], str(root)))
    browser.open(f"{served['url']}/#s={NAME}")
    got = browser.evaluate(PROBE.replace("__N__", "1"))
    (box,) = got["boxes"]
    assert box["href"] == f"api/md-image/{SID}/{UUID}/0/0" and box["caption"] == "home" and box["natural"] == 640, got
    # the fenced image stays code
    assert browser.evaluate("document.querySelectorAll('#chat .md pre code')[0].textContent.includes('![fenced]')")
    assert browser.evaluate("document.querySelectorAll('#chat .md-local').length") == 1


def test_an_image_that_will_not_decode_says_so_not_a_broken_icon(root, served, browser):
    transcript_file(served).write_text(assistant_line(["![photo](~/shots/photo.jpg)"], str(root)))  # photo.jpg is not a decodable image
    browser.open(f"{served['url']}/#s={NAME}")
    got = browser.evaluate(PROBE.replace("__N__", "1"))
    (box,) = got["boxes"]
    assert not box["hasImg"] and box["missing"].startswith("image not shown: ") and box["caption"] == "photo", got
