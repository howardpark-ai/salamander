"""Images a session sends ("sala's chat doesn't show images a session produces").

A session delivers a file to the owner with the SendUserFile tool: the transcript holds the paths as the call's input and
the result's attachments, and the file is on disk, not in the transcript. sala-web shows an image among them inline in
the reply, through /api/file-image/<sid>/<uuid>/<i>/<k>. The line shapes come from a real transcript
(fixtures/send-user-file.jsonl: a SendUserFile call with a png, a docx and a jpg, and its result line; the paths are
placeholders, the keys are the transcript's own). Checked here: the parser's blocks, what the file reader refuses (the
guard follows the uploads route's: an image type allow-list, a size cap, no path from the request, nothing outside the
allowed roots, nothing hidden or secret-named), the route, and the page in a headless Chromium (skipped when none).
"""

from __future__ import annotations

import json
import os
import struct
import zlib
from pathlib import Path

import pytest
from starlette.testclient import TestClient

from conftest import NAME, SID, transcript_file
from sala_web import sentimages as SI
from sala_web import transcript as TR
from sala_web.app import create_app
from sala_web.config import Settings

FIXTURE = (Path(__file__).parent / "fixtures" / "send-user-file.jsonl").read_text()
USE_UUID = "00000000-0000-4000-8000-0000000000a1"
RESULT_UUID = "00000000-0000-4000-8000-0000000000a2"


def png(w: int = 64, h: int = 48) -> bytes:
    """A real w x h png (grey), small enough to ship in a test."""
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    raw = b"".join(b"\x00" + b"\x80" * w for _ in range(h))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 0, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


JPG = b"\xff\xd8\xff\xe0" + b"\x00" * 64
GIF = b"GIF89a" + b"\x00" * 64
WEBP = b"RIFF\x24\x00\x00\x00WEBPVP8 " + b"\x00" * 64


def fixture_lines(root: Path) -> list[dict]:
    return [json.loads(l) for l in FIXTURE.replace("@ROOT@", str(root)).splitlines()]


@pytest.fixture
def root(tmp_path, monkeypatch) -> Path:
    """The only place a sent image may be read from in a test (the app is built after this: list it before `served`)."""
    r = tmp_path / "home"
    (r / "shots").mkdir(parents=True)
    (r / "reports").mkdir()
    monkeypatch.setenv("SALA_WEB_IMAGE_ROOTS", str(r))
    return r


def roots(r: Path) -> list[Path]:
    return [r]


# ---------- the parser ----------


def test_send_user_file_gives_an_inline_block_for_each_image_only(tmp_path):
    use, result = fixture_lines(tmp_path)
    m = TR.parse_line(use, SID)
    kinds = [b["kind"] for b in m["blocks"]]
    assert kinds == ["tool_use", "file_image", "file_image"]  # the docx stays in the tool call
    one, two = m["blocks"][1:]
    assert one["url"] == f"api/file-image/{SID}/{USE_UUID}/0/0" and one["name"] == "overview.png"
    assert two["url"] == f"api/file-image/{SID}/{USE_UUID}/0/2" and two["name"] == "detail.jpg"  # k counts all files
    assert one["caption"] == "Overview screenshot and the report" and two["caption"] == ""  # the caption once
    assert "path" not in one and str(tmp_path) not in json.dumps([one, two])  # the page is never given a path
    # the result line is an ordinary tool result: the images are shown once, from the call
    r = TR.parse_line(result, SID)
    assert [b["kind"] for b in r["blocks"]] == ["tool_result"] and r["blocks"][0]["images"] == []


def test_only_an_assistants_send_user_file_call_makes_an_image_block(tmp_path):
    use, _ = fixture_lines(tmp_path)
    other = json.loads(json.dumps(use))
    other["message"]["content"][0]["name"] = "Read"
    assert [b["kind"] for b in TR.parse_line(other, SID)["blocks"]] == ["tool_use"]
    bad = json.loads(json.dumps(use))
    bad["message"]["content"][0]["input"] = {"files": "not-a-list"}
    assert [b["kind"] for b in TR.parse_line(bad, SID)["blocks"]] == ["tool_use"]
    objects = json.loads(json.dumps(use))
    objects["message"]["content"][0]["input"] = {"files": [{"path": "/x/a.webp"}, 7, None, {"nope": 1}]}
    assert [b["kind"] for b in TR.parse_line(objects, SID)["blocks"]] == ["tool_use", "file_image"]
    # the caption goes with the first image, even when a document comes before it
    later = json.loads(json.dumps(use))
    later["message"]["content"][0]["input"]["files"] = ["/x/a.docx", "/x/b.png"]
    assert TR.parse_line(later, SID)["blocks"][1]["caption"] == "Overview screenshot and the report"


def test_find_sent_file_reads_the_named_place_in_the_transcript(tmp_path):
    p = tmp_path / "t.jsonl"
    p.write_text(FIXTURE.replace("@ROOT@", "/work"))
    assert TR.find_sent_file(p, USE_UUID, 0, 0) == ("/work/shots/overview.png", "/work")
    assert TR.find_sent_file(p, USE_UUID, 0, 2) == ("/work/shots/detail.jpg", "/work")
    assert TR.find_sent_file(p, USE_UUID, 0, 3) is None  # no such file in the call
    assert TR.find_sent_file(p, USE_UUID, 1, 0) is None  # no such block
    assert TR.find_sent_file(p, RESULT_UUID, 0, 0) is None  # a tool_result is not a SendUserFile call
    assert TR.find_sent_file(p, "00000000-0000-4000-8000-0000000000ff", 0, 0) is None


# ---------- the file reader's guard ----------


def put(path: Path, data: bytes) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return path


def test_the_four_image_types_are_served_by_their_first_bytes(root):
    for name, data, mt in (("a.png", png(), "image/png"), ("b.jpg", JPG, "image/jpeg"), ("c.jpeg", JPG, "image/jpeg"),
                           ("d.gif", GIF, "image/gif"), ("e.webp", WEBP, "image/webp"), ("F.PNG", png(), "image/png")):
        p = put(root / "shots" / name, data)
        assert SI.read_sent_image(str(p), "", roots(root)) == (mt, data), name


def test_a_file_that_is_not_an_image_is_refused_whatever_its_name(root):
    assert SI.read_sent_image(str(put(root / "x.png", b"#!/bin/sh\necho hi\n")), "", roots(root)) is None
    assert SI.read_sent_image(str(put(root / "y.png", b"<svg xmlns='http://www.w3.org/2000/svg'/>")), "", roots(root)) is None
    # a real image under a name that is not an image type, and an svg by name
    assert SI.read_sent_image(str(put(root / "z.txt", png())), "", roots(root)) is None
    assert SI.read_sent_image(str(put(root / "w.svg", png())), "", roots(root)) is None
    assert SI.read_sent_image(str(put(root / "v.pdf", b"%PDF-1.7")), "", roots(root)) is None
    assert SI.read_sent_image(str(put(root / "u.png", b"")), "", roots(root)) is None


def test_nothing_outside_the_roots_nothing_hidden_nothing_secret(root, tmp_path):
    outside = put(tmp_path / "elsewhere" / "pic.png", png())
    assert SI.read_sent_image(str(outside), "", roots(root)) is None
    # traversal out of a root, in the name
    assert SI.read_sent_image(f"{root}/shots/../../elsewhere/pic.png", "", roots(root)) is None
    assert SI.read_sent_image("/etc/../etc/hostname.png", "", roots(root)) is None
    # hidden directories and files under a root: ~/.ssh, ~/.config, ~/.claude and the like
    for rel in (".ssh/pic.png", ".config/app/pic.png", ".claude/projects/pic.png", "shots/.hidden.png", ".local/state/sala-web/uploads/pic.png"):
        assert SI.read_sent_image(str(put(root / rel, png())), "", roots(root)) is None, rel
    # a name that says it holds a secret
    for rel in ("shots/api-token.png", "shots/Credentials.png", "secrets/pic.png", "shots/password.png", "id_rsa/pic.png"):
        assert SI.read_sent_image(str(put(root / rel, png())), "", roots(root)) is None, rel
    # the root itself is not a file, and a NUL is never a path
    assert SI.read_sent_image(str(root), "", roots(root)) is None
    assert SI.read_sent_image(str(root / "shots" / "a.png\x00.txt"), "", roots(root)) is None
    # the control: an ordinary one is served
    assert SI.read_sent_image(str(put(root / "shots" / "ok.png", png())), "", roots(root)) is not None


def test_a_link_cannot_lead_out_of_the_roots_or_into_a_hidden_place(root, tmp_path):
    outside = put(tmp_path / "elsewhere" / "pic.png", png())
    link = root / "shots" / "link.png"
    link.symlink_to(outside)
    assert SI.read_sent_image(str(link), "", roots(root)) is None  # a link out
    hidden = put(root / ".ssh" / "pic.png", png())
    link2 = root / "shots" / "to-hidden.png"
    link2.symlink_to(hidden)
    assert SI.read_sent_image(str(link2), "", roots(root)) is None  # a link into ~/.ssh
    dirlink = root / "shots" / "dirlink"
    dirlink.symlink_to(tmp_path / "elsewhere")
    assert SI.read_sent_image(str(dirlink / "pic.png"), "", roots(root)) is None  # a link to a directory out
    inner = put(root / "shots" / "real.png", png())
    link3 = root / "reports" / "inner.png"
    link3.symlink_to(inner)
    assert SI.read_sent_image(str(link3), "", roots(root)) is not None  # a link that stays inside is fine


def test_a_relative_path_is_read_against_the_working_directory_and_a_tilde_against_home(root, monkeypatch):
    p = put(root / "shots" / "rel.png", png())
    assert SI.read_sent_image("shots/rel.png", str(root), roots(root)) is not None
    assert SI.read_sent_image("shots/rel.png", "", roots(root)) is None  # no directory to read it against
    assert SI.read_sent_image("../outside.png", str(root / "shots"), roots(root)) is None
    monkeypatch.setenv("HOME", str(root))
    assert SI.read_sent_image("~/shots/rel.png", "", roots(root)) is not None
    assert p.exists()


def test_the_size_cap(root):
    p = put(root / "shots" / "big.png", png() + b"\x00" * 2000)
    assert SI.read_sent_image(str(p), "", roots(root), max_bytes=len(p.read_bytes())) is not None
    assert SI.read_sent_image(str(p), "", roots(root), max_bytes=len(p.read_bytes()) - 1) is None
    assert SI.MAX_BYTES == 15 * 1024 * 1024


def test_default_roots_are_home_and_the_session_scratch_directory(monkeypatch):
    monkeypatch.delenv("SALA_WEB_IMAGE_ROOTS", raising=False)
    assert Settings().image_roots == [Path.home(), Path(f"/tmp/claude-{os.getuid()}")]
    monkeypatch.setenv("SALA_WEB_IMAGE_ROOTS", "/a:/b")
    assert Settings().image_roots == [Path("/a"), Path("/b")]


# ---------- the route ----------


@pytest.fixture
def client(root, tmp_path):
    claude = tmp_path / "claude"
    proj = claude / "projects" / TR.project_slug(str(root))
    proj.mkdir(parents=True)
    (proj / f"{SID}.jsonl").write_text(FIXTURE.replace("@ROOT@", str(root)))
    put(root / "shots" / "overview.png", png())
    put(root / "shots" / "detail.jpg", JPG)
    put(root / "reports" / "summary.docx", b"PK\x03\x04")
    settings = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude,
                        tmux_socket_name="salaweb-pytest-none", roles_cmd=["false"], sala_models=tmp_path / "none.tsv",
                        admin_key=tmp_path / "none-key")
    return TestClient(create_app(settings))


def test_route_serves_the_image_with_its_type_and_safe_headers(client):
    r = client.get(f"/api/file-image/{SID}/{USE_UUID}/0/0")
    assert r.status_code == 200 and r.headers["content-type"] == "image/png" and r.content.startswith(b"\x89PNG")
    assert r.headers["x-content-type-options"] == "nosniff"
    assert "sandbox" in r.headers["content-security-policy"] and "private" in r.headers["cache-control"]
    r = client.get(f"/api/file-image/{SID}/{USE_UUID}/0/2")
    assert r.status_code == 200 and r.headers["content-type"] == "image/jpeg"


def test_route_refuses_what_is_not_a_sent_image(client, root):
    assert client.get(f"/api/file-image/{SID}/{USE_UUID}/0/1").status_code == 404  # the docx
    assert client.get(f"/api/file-image/{SID}/{USE_UUID}/0/9").status_code == 404  # no such file in the call
    assert client.get(f"/api/file-image/{SID}/{USE_UUID}/3/0").status_code == 404  # no such block
    assert client.get(f"/api/file-image/{SID}/{RESULT_UUID}/0/0").status_code == 404  # not a SendUserFile call
    assert client.get(f"/api/file-image/{SID}/00000000-0000-4000-8000-0000000000ff/0/0").status_code == 404
    assert client.get(f"/api/file-image/{'bb' * 8}-0000-4000-8000-000000000001/{USE_UUID}/0/0").status_code == 404  # no transcript
    assert client.get(f"/api/file-image/{SID}/{USE_UUID}/x/0").status_code == 404  # not a number: no route
    assert client.get(f"/api/file-image/{SID}/{USE_UUID}/-1/0").status_code == 404
    assert client.get(f"/api/file-image/{SID}/{USE_UUID}/0/-1").status_code == 404  # not Python's last file
    assert client.get(f"/api/file-image/{SID}/%2e%2e%2f{USE_UUID}/0/0").status_code in (400, 404)
    (root / "shots" / "overview.png").unlink()
    assert client.get(f"/api/file-image/{SID}/{USE_UUID}/0/0").status_code == 404  # the file is gone


def test_route_takes_the_path_from_the_transcript_only(client, root, tmp_path):
    """A transcript that names a file outside the roots, or a hidden one, gets no image from the route."""
    claude = tmp_path / "claude" / "projects" / TR.project_slug(str(root)) / f"{SID}.jsonl"
    secret = put(tmp_path / "elsewhere" / "pic.png", png())
    hidden = put(root / ".ssh" / "pic.png", png())
    for named in (secret, hidden, "/etc/passwd.png", f"{root}/shots/../../elsewhere/pic.png"):
        text = FIXTURE.replace("@ROOT@", str(root)).replace(f"{root}/shots/overview.png", str(named))
        claude.write_text(text)
        assert client.get(f"/api/file-image/{SID}/{USE_UUID}/0/0").status_code == 404, named


# ---------- the page ----------


PROBE = r"""
new Promise((res) => {
  const t0 = Date.now();
  (function poll() {
    if (document.querySelectorAll("#chat figure.sent").length < 2 && Date.now() - t0 < 15000) return setTimeout(poll, 100);
    const t1 = Date.now();
    (function wait() {
      const all = [...document.querySelectorAll("#chat figure.sent img")];
      if (all.some((i) => !i.complete) && Date.now() - t1 < 10000) return setTimeout(wait, 100);
      setTimeout(() => {
      const out = [...document.querySelectorAll("#chat figure.sent")].map((f) => {
        const img = f.querySelector("img"), a = f.querySelector("a");
        const r = img ? img.getBoundingClientRect() : { width: 0, height: 0, right: 0 };
        return { hasImg: !!img, src: img && img.getAttribute("src"), loading: img && img.getAttribute("loading"),
                 natural: img && img.naturalWidth, w: r.width, h: r.height, right: r.right,
                 href: a && a.getAttribute("href"), target: a && a.getAttribute("target"), rel: a && a.getAttribute("rel"),
                 caption: (f.querySelector("figcaption") || {}).textContent || null, text: f.textContent.trim(),
                 visible: !!(f.offsetParent), msgVisible: !!(f.closest(".msg").offsetParent),
                 hideTools: document.body.classList.contains("hide-tools") };
      });
      res({ width: innerWidth, scrollW: document.documentElement.scrollWidth, figs: out });
      }, 400);  // an image that failed to load swaps itself for its name in its error handler
    })();
  })();
})
"""


def test_the_chat_shows_a_sent_image_inline_at_390px(root, served, browser):
    put(root / "shots" / "overview.png", png(640, 480))
    put(root / "shots" / "detail.jpg", JPG)  # not a decodable image: the page falls back to the file's name
    with transcript_file(served).open("a") as f:
        f.write(FIXTURE.replace("@ROOT@", str(root)))
    browser.open(f"{served['url']}/#s={NAME}")
    got = browser.evaluate(PROBE)
    assert got["width"] == 390 and got["scrollW"] <= 390, got  # no sideways scroll on a phone
    first, second = got["figs"]
    # the tool folds are hidden (the default), the image is not: it is in the reply, not in the call's fold
    assert first["hideTools"] and first["msgVisible"] and first["visible"], first
    assert first["src"] == f"api/file-image/{SID}/{USE_UUID}/0/0" and first["loading"] == "lazy", first
    assert first["natural"] == 640 and 0 < first["w"] <= 390 and first["right"] <= 390 and first["h"] > 40, first
    assert first["href"] == first["src"] and first["target"] == "_blank" and "noopener" in first["rel"], first  # tap to open
    assert first["caption"] == "Overview screenshot and the report", first
    # an image that does not load shows its name, not a broken-image icon
    assert not second["hasImg"] and second["text"] == "Image not available: detail.jpg", second


def test_a_refused_file_shows_its_name_in_the_page(root, served, browser):
    with transcript_file(served).open("a") as f:
        f.write(FIXTURE.replace("@ROOT@", str(root)))  # the files do not exist under root
    browser.open(f"{served['url']}/#s={NAME}")
    got = browser.evaluate(PROBE)
    assert [f["text"] for f in got["figs"]] == ["Image not available: overview.png", "Image not available: detail.jpg"]
