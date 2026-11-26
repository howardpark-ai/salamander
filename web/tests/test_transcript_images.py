"""The images a transcript line holds as base64, served through /api/image/<sid>/<uuid>/<i>/<j>.

The media type of such a block is whatever the line says, so the route answers only for the raster types the app shows
(png, jpeg, gif, webp), any other type being the same 404 as no image, and each answer carries nosniff and the sandboxing
Content-Security-Policy of the other image routes. Checked: the route through a test client, and, in a headless Chromium
(skipped when none), that under those headers the chat still draws the image and its URL opened in the tab still shows it.
The temp folder of the route's tests is locked while a test runs and removed afterwards, pass or fail.
"""

from __future__ import annotations

import base64
import json
import time

import pytest
from starlette.testclient import TestClient

from conftest import NAME, SID, transcript_file, transcript_line
from sala_web.app import create_app
from sala_web.config import Settings
from test_md_images import Folder
from test_sent_images import GIF, JPG, WEBP, png

UUID = "00000000-0000-4000-8000-0000000000d1"
CSP = "default-src 'none'; sandbox"
SVG = b"<svg xmlns='http://www.w3.org/2000/svg'><script>alert(1)</script></svg>"


def image_block(data: bytes, media_type: object = None, kind: str = "image") -> dict:
    source = {"type": "base64", "data": base64.b64encode(data).decode()}
    if media_type is not None:
        source["media_type"] = media_type
    return {"type": kind, "source": source}


def both_places(block: dict) -> list[dict]:
    """The block as content[0] of a line, and again inside a tool result as content[1].content[0]."""
    return [block, {"type": "tool_result", "tool_use_id": "t9", "content": [block]}]


URLS = (f"/api/image/{SID}/{UUID}/0/-1", f"/api/image/{SID}/{UUID}/1/0")


@pytest.fixture
def served_line():
    """A function: write one transcript line with these content blocks, and give a client of the app that reads it."""
    top = Folder("salaweb-trimg-")

    def make(content: list[dict]) -> TestClient:
        proj = top.path / "claude" / "projects" / "-work"
        proj.mkdir(parents=True, exist_ok=True)
        (proj / f"{SID}.jsonl").write_text(transcript_line("user", content, UUID))
        settings = Settings(socket=top.path / "s.sock", state_dir=top.path / "state", claude_dir=top.path / "claude",
                            tmux_socket_name="salaweb-pytest-none", roles_cmd=["false"], sala_models=top.path / "none.tsv",
                            admin_key=top.path / "none-key")
        return TestClient(create_app(settings))

    try:
        yield make
    finally:
        top.close()


@pytest.mark.parametrize("media_type, data", [("image/png", png()), ("image/jpeg", JPG), ("image/gif", GIF), ("image/webp", WEBP),
                                              (None, png())],  # a line with no media type is read as a png
                         ids=["png", "jpeg", "gif", "webp", "no-media-type"])
def test_the_route_serves_a_raster_image_with_safe_headers(served_line, media_type, data):
    client = served_line(both_places(image_block(data, media_type)))
    for url in URLS:
        r = client.get(url)
        assert r.status_code == 200 and r.content == data, (url, r.status_code)
        assert r.headers["content-type"] == (media_type or "image/png")
        assert r.headers["x-content-type-options"] == "nosniff"
        assert r.headers["content-security-policy"] == CSP
        assert r.headers["cache-control"] == "private, max-age=86400"


@pytest.mark.parametrize("media_type", [
    "image/svg+xml", "text/html", "text/javascript", "application/pdf", "application/octet-stream", "image/bmp",
    "image/png; charset=utf-8", "image/png, text/html", "IMAGE/PNG",
    7, ["image/png"], {"image/png": 1},  # not even a string
])
def test_any_other_type_is_the_404_of_no_image(served_line, media_type):
    client = served_line(both_places(image_block(SVG, media_type)))
    none = client.get(f"/api/image/{SID}/{UUID}/9/-1")  # no such block
    assert none.status_code == 404 and none.json() == {"ok": False, "error": "no image"}
    for url in URLS:
        r = client.get(url)
        assert (r.status_code, r.content, r.headers["content-type"]) == (404, none.content, "application/json"), url


def test_a_document_block_is_not_served(served_line):
    client = served_line(both_places(image_block(b"%PDF-1.4\n", "application/pdf", kind="document")))
    for url in URLS:
        assert client.get(url).status_code == 404, url


# ---------- the page, and the image opened in the tab ----------


THUMB = r"""
new Promise((res) => {
  const t0 = Date.now();
  (function poll() {
    const img = document.querySelector("#chat .msg.user img.thumb");
    if ((!img || !img.complete) && Date.now() - t0 < 15000) return setTimeout(poll, 100);
    res(img && { src: img.getAttribute("src"), natural: img.naturalWidth, href: img.parentElement.getAttribute("href"),
                 target: img.parentElement.getAttribute("target") });
  })();
})
"""
OPENED = ("location.pathname.includes('/api/image/') && document.images.length === 1 && document.images[0].complete"
          " ? { type: document.contentType, natural: document.images[0].naturalWidth } : null")


def test_the_chat_draws_the_image_and_its_url_opens_in_the_tab(served, browser):
    with transcript_file(served).open("a") as f:
        f.write(transcript_line("user", [{"type": "text", "text": "a picture"}, image_block(png(120, 90), "image/png")], UUID))
    browser.open(f"{served['url']}/#s={NAME}")
    thumb = browser.evaluate(THUMB)
    url = f"api/image/{SID}/{UUID}/1/-1"
    assert thumb == {"src": url, "natural": 120, "href": url, "target": "_blank"}, thumb
    browser.send("Page.navigate", {"url": f"{served['url']}/{url}"})  # what a tap on the thumbnail opens
    end, got = time.time() + 15, None
    while got is None and time.time() < end:
        try:
            got = browser.evaluate(OPENED)
        except RuntimeError:  # the call fell on the document the navigation replaced
            pass
        if got is None:
            time.sleep(0.1)
    assert got == {"type": "image/png", "natural": 120}, json.dumps(got)
