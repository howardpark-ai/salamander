"""Any file into the composer (an mp4 video pasted into the composer was not accepted): POST /api/upload?name=<file name> streams the body to
uploads/<random folder>/<safe name>; the image path (a flat random name, 20 MB) is untouched.
"""

from __future__ import annotations

import os
import stat
import time

import pytest
from starlette.testclient import TestClient

from sala_web import app as A
from sala_web.app import create_app, safe_upload_name, valid_file_ref
from sala_web.config import Settings

MP4 = b"\x00\x00\x00\x18ftypmp42\x00\x00\x00\x00mp42isom" + bytes(range(256)) * 40  # binary, not text, not an image
PDF = b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n1 0 obj\n<< /Type /Catalog >>\nendobj\n%%EOF\n"
OCTET = {"Content-Type": "application/octet-stream"}
PNG_BYTES = b"\x89PNG\r\n\x1a\n" + b"\x00" * 64


def make(tmp_path, **kw) -> tuple[TestClient, Settings]:
    settings = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=tmp_path / "claude",
                        tmux_socket_name="salaweb-pytest-none", roles_cmd=["false"], sala_models=tmp_path / "none.tsv",
                        admin_key=tmp_path / "none-key", min_free_bytes=0, **kw)
    return TestClient(create_app(settings)), settings


def entries(settings: Settings) -> list:
    return sorted(settings.uploads_dir.rglob("*")) if settings.uploads_dir.is_dir() else []


def test_an_mp4_like_body_is_stored_under_a_random_folder_with_its_own_name(tmp_path):
    c, st = make(tmp_path)
    r = c.post("/api/upload", params={"name": "holiday clip.mp4"}, content=MP4, headers={"Content-Type": "video/mp4"})
    assert r.status_code == 200, r.text
    d = r.json()
    folder, _, name = d["name"].partition("/")
    assert len(folder) == 32 and name == "holiday_clip.mp4" == d["fileName"] and d["size"] == len(MP4) and d["file"] is True
    dest = st.uploads_dir / folder / name
    assert d["path"] == str(dest) and dest.read_bytes() == MP4
    assert stat.S_IMODE(dest.stat().st_mode) == 0o600 and stat.S_IMODE(dest.parent.stat().st_mode) == 0o700
    assert [p.name for p in dest.parent.iterdir()] == [name]  # no temporary file left beside it


def test_a_pdf_lands_beside_nothing_else_and_two_uploads_of_one_name_do_not_collide(tmp_path):
    c, st = make(tmp_path)
    a = c.post("/api/upload", params={"name": "report.pdf"}, content=PDF, headers=OCTET).json()
    b = c.post("/api/upload", params={"name": "report.pdf"}, content=PDF + b"2", headers=OCTET).json()
    assert a["name"] != b["name"] and a["fileName"] == b["fileName"] == "report.pdf"
    assert (st.uploads_dir / a["name"]).read_bytes() == PDF and (st.uploads_dir / b["name"]).read_bytes() == PDF + b"2"


@pytest.mark.parametrize("raw, want", [
    ("../../etc/passwd", "passwd"),
    ("..\\..\\windows\\system32\\cmd.exe", "cmd.exe"),
    ("a b(c).pdf", "a_b_c_.pdf"),
    (".hidden", "hidden"),
    ("...", "file"),
    ("..", "file"),
    ("", "file"),
    ("   ", "_"),
    ("a\x00b\nc\td e.txt", "abcd_e.txt"),
    ("a..b...c.txt", "a.b.c.txt"),
    ("한글 보고서 (최종).pdf", "한글_보고서_최종_.pdf"),
    ("naïve café.txt", "naïve_café.txt"),
    ("x" * 300 + ".pdf", "x" * 116 + ".pdf"),
    ("한" * 200 + ".pdf", "한" * 78 + ".pdf"),
    ("a;rm -rf $(x)`y`&|>.sh", "a_rm_-rf_x_y_.sh"),
    ("archive.tar.gz", "archive.tar.gz"),
    ("noext", "noext"),
    ("trailing.", "trailing."),
])
def test_the_name_made_safe(tmp_path, raw, want):
    assert safe_upload_name(raw) == want
    assert safe_upload_name(want) == want  # idempotent: what the server stored is what send validates
    assert len(want) <= 120 and len(want.encode()) <= 240 and not want.startswith(".")
    c, st = make(tmp_path)
    r = c.post("/api/upload", params={"name": raw}, content=b"data", headers=OCTET)
    assert r.status_code == 200, r.text
    folder, _, name = r.json()["name"].partition("/")
    assert name == want
    dest = (st.uploads_dir / folder / name).resolve()
    assert dest.parent == (st.uploads_dir / folder).resolve() and dest.is_relative_to(st.uploads_dir.resolve()) and dest.read_bytes() == b"data"
    assert valid_file_ref(r.json()["name"])


def test_a_long_name_keeps_its_extension_and_a_long_extension_is_cut_whole():
    long_ext = safe_upload_name("a." + "e" * 50)
    assert len(long_ext) <= 120 and long_ext.startswith("a.eee")
    assert safe_upload_name("y" * 119 + ".mp4") == "y" * 116 + ".mp4"
    assert safe_upload_name("y" * 300).endswith("y") and len(safe_upload_name("y" * 300)) == 120


@pytest.mark.parametrize("ref, ok", [
    ("a" * 32 + "/clip.mp4", True),
    ("0123456789abcdef0123456789abcdef/한글.pdf", True),
    ("a" * 32 + "/../../etc/passwd", False),
    ("a" * 32 + "/..", False),
    ("a" * 32 + "/a..b", False),
    ("a" * 32 + "/.hidden", False),
    ("a" * 32 + "/sub/file.txt", False),
    ("a" * 32 + "/with space.txt", False),
    ("a" * 32 + "/semi;colon", False),
    ("a" * 32 + "/", False),
    ("/" + "a" * 32 + "/x", False),
    ("A" * 32 + "/x", False),
    ("a" * 31 + "/x", False),
    ("../" + "a" * 32 + "/x", False),
    ("a" * 32 + "/x\x00y", False),
    ("a" * 32 + "/" + "z" * 121, False),
    ("a" * 32, False),
])
def test_valid_file_ref(ref, ok):
    assert valid_file_ref(ref) is ok


@pytest.fixture
def live(tmp_path):
    """The app on a real loopback port (uvicorn), for a body that arrives in pieces: the test client hands the app the
    whole body at once."""
    import socket
    import threading

    import uvicorn

    def start(**kw):
        _, settings = make(tmp_path, **kw)
        with socket.socket() as sk:
            sk.bind(("127.0.0.1", 0))
            port = sk.getsockname()[1]
        server = uvicorn.Server(uvicorn.Config(create_app(settings), host="127.0.0.1", port=port, log_level="warning"))
        threading.Thread(target=server.run, daemon=True).start()
        for _ in range(100):
            if server.started:
                break
            time.sleep(0.05)
        assert server.started
        servers.append(server)
        return f"http://127.0.0.1:{port}", settings

    servers: list = []
    yield start
    for sv in servers:
        sv.should_exit = True


def post_chunked(url: str, name: str, chunks) -> tuple[int | None, dict]:
    """POST with Transfer-Encoding: chunked (no Content-Length), the pieces sent one at a time; (status, JSON) of the answer,
    status None when the server closed before the client finished and said nothing."""
    import http.client
    import json
    from urllib.parse import quote, urlsplit

    conn = http.client.HTTPConnection(urlsplit(url).netloc, timeout=20)
    conn.putrequest("POST", "/api/upload?name=" + quote(name))
    conn.putheader("Content-Type", "application/octet-stream")
    conn.putheader("Transfer-Encoding", "chunked")
    conn.endheaders()
    try:
        for ch in chunks:
            conn.send(b"%x\r\n" % len(ch) + ch + b"\r\n")
            time.sleep(0.02)
        conn.send(b"0\r\n\r\n")
    except OSError:
        pass  # the server answered and closed while the client was still sending
    try:
        r = conn.getresponse()
        return r.status, json.loads(r.read() or b"{}")
    except (OSError, http.client.HTTPException):
        return None, {}
    finally:
        conn.close()


def test_over_the_limit_while_streaming_is_refused_and_no_partial_file_stays(live):
    url, st = live(max_file_upload_bytes=int(2.5 * 1024 * 1024))
    # the limit is met in the middle of the stream, after megabytes were flushed to the partial file
    status, d = post_chunked(url, "big.mp4", (b"v" * (512 * 1024) for _ in range(8)))
    assert status in (413, None), status
    if status:
        assert "too large" in d["error"] and "MB" in d["error"]
    for _ in range(60):
        if not entries(st):
            break
        time.sleep(0.05)
    assert entries(st) == []
    # the whole thing, under the limit, streamed in pieces, arrives intact
    chunks = [bytes([i]) * (512 * 1024) for i in range(4)]
    status, d = post_chunked(url, "ok.bin", chunks)
    assert status == 200 and d["size"] == 2 * 1024 * 1024
    assert (st.uploads_dir / d["name"]).read_bytes() == b"".join(chunks)


def test_a_declared_size_over_the_limit_is_refused_before_a_byte_is_read(tmp_path):
    c, st = make(tmp_path, max_file_upload_bytes=1000)
    r = c.post("/api/upload", params={"name": "big.mp4"}, content=b"v" * 3000, headers=OCTET)
    assert r.status_code == 413 and entries(st) == []
    r = c.post("/api/upload", params={"name": "ok.bin"}, content=b"v" * 1000, headers=OCTET)
    assert r.status_code == 200 and r.json()["size"] == 1000


def test_a_file_that_would_leave_the_disk_under_the_floor_is_refused(tmp_path):
    c, st = make(tmp_path)
    st.min_free_bytes = 10**18
    r = c.post("/api/upload", params={"name": "x.bin"}, content=b"12345", headers=OCTET)
    assert r.status_code == 507 and "disk space" in r.json()["error"]
    assert entries(st) == []


def test_empty_file_and_a_type_without_a_name_are_refused(tmp_path):
    c, st = make(tmp_path)
    r = c.post("/api/upload", params={"name": "empty.txt"}, content=b"", headers=OCTET)
    assert r.status_code == 400 and "empty" in r.json()["error"] and entries(st) == []
    r = c.post("/api/upload", content=b"x", headers={"Content-Type": "text/plain"})  # a bare POST of a type is not a file
    assert r.status_code == 415 and entries(st) == []


@pytest.mark.parametrize("name, ctype, want", [
    ("pasted-1791991172262.png", "application/octet-stream", "pasted-1791991172262.png"),   # an unnamed png, named by the page
    ("pasted-1791991172262.bin", "application/octet-stream", "pasted-1791991172262.bin"),   # a type that says nothing
    ("pasted-1791991172262.mp4", "video/mp4", "pasted-1791991172262.mp4"),
    ("", "application/octet-stream", "file"),                                                  # no name at all: still stored
])
def test_a_generated_name_for_an_unnamed_android_paste_is_accepted(tmp_path, name, ctype, want):
    """An Android keyboard's image can arrive as a File with an empty name; the page names it from its type
    (pasted-<time>.<ext>, .bin when the type is unknown) and the server stores it, whatever the extension."""
    c, st = make(tmp_path)
    r = c.post("/api/upload", params={"name": name}, content=PNG_BYTES, headers={"Content-Type": ctype})
    assert r.status_code == 200, r.text
    d = r.json()
    assert d["fileName"] == want and valid_file_ref(d["name"]) and (st.uploads_dir / d["name"]).read_bytes() == PNG_BYTES


def test_a_failure_while_finishing_leaves_nothing(tmp_path, monkeypatch):
    c, st = make(tmp_path)

    def boom(*a, **k):
        raise OSError("disk went away")

    monkeypatch.setattr(A.os, "replace", boom)
    with pytest.raises(OSError):
        c.post("/api/upload", params={"name": "cut.mp4"}, content=b"x" * 5000, headers=OCTET)
    assert entries(st) == []


def test_cross_origin_is_refused_for_a_file_too(tmp_path):
    c, st = make(tmp_path)
    r = c.post("/api/upload", params={"name": "x.txt"}, content=b"x", headers={**OCTET, "Origin": "https://evil.example"})
    assert r.status_code == 403 and entries(st) == []


def test_images_keep_their_flat_random_name_and_their_limit(tmp_path):
    c, st = make(tmp_path, max_upload_bytes=1000)
    r = c.post("/api/upload", content=b"\x89PNG fake", headers={"Content-Type": "image/png"})
    assert r.status_code == 200 and "/" not in r.json()["name"] and r.json()["name"].endswith(".png")
    assert (st.uploads_dir / r.json()["name"]).read_bytes() == b"\x89PNG fake"
    # a name beside an image type changes nothing: still flat, still the image limit
    r = c.post("/api/upload", params={"name": "../../x.png"}, content=b"\x89PNG", headers={"Content-Type": "image/png"})
    assert r.status_code == 200 and "/" not in r.json()["name"]
    r = c.post("/api/upload", content=b"x" * 2000, headers={"Content-Type": "image/png"})
    assert r.status_code == 413 and r.json()["error"] == "image too large"
    # the image limit does not cap a file
    r = c.post("/api/upload", params={"name": "a.bin"}, content=b"x" * 2000, headers=OCTET)
    assert r.status_code == 200


def test_no_route_serves_an_upload_back(tmp_path):
    c, _ = make(tmp_path)
    ref = c.post("/api/upload", params={"name": "page.html"}, content=b"<script>alert(1)</script>", headers=OCTET).json()["name"]
    routes = [getattr(r, "path", "") for r in c.app.routes]
    assert [p for p in routes if "upload" in p] == ["/api/upload"]
    for url in (f"/uploads/{ref}", f"/api/uploads/{ref}", f"/api/upload/{ref}", f"/static/uploads/{ref}"):
        r = c.get(url)
        assert b"alert(1)" not in r.content, url


def test_prune_removes_an_old_folder_and_a_half_written_one_and_keeps_a_new_one(tmp_path):
    c, st = make(tmp_path)
    up = st.uploads_dir
    up.mkdir(parents=True)

    def folder(hexid: str, files: list[str], age_days: float) -> None:
        d = up / (hexid * 32)
        d.mkdir()
        for f in files:
            (d / f).write_bytes(b"x")
        t = time.time() - age_days * 86400
        os.utime(d, (t, t))

    folder("a", ["old.mp4"], 31)                # past 30 days: gone
    folder("b", ["new.mp4"], 1)                 # new: stays
    folder("c", ["fresh.mp4"], 29)              # inside 30 days: stays
    folder("d", [A.UPLOAD_PARTIAL], 1.5)        # half-written and older than a day: gone
    folder("e", [A.UPLOAD_PARTIAL], 0.01)       # half-written but just now (still streaming): stays
    (up / "notes").mkdir()                      # not ours (no random name): left alone
    old_image = up / ("f" * 32 + ".png")
    old_image.write_bytes(b"x")
    t = time.time() - 31 * 86400
    os.utime(old_image, (t, t))
    with TestClient(c.app):                     # the app's start prunes
        pass
    left = sorted(p.name for p in up.iterdir())
    assert left == sorted(["b" * 32, "c" * 32, "e" * 32, "notes"])
