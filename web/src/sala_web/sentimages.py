"""Image files a session sends to the owner (the SendUserFile tool), served to the chat.

A session delivers a file with SendUserFile(files=[path, ...], caption=...): the transcript holds the paths as the tool
call's input, and the file itself is on this machine, not in the transcript. sala-web shows an image among them inline
in the reply, through GET /api/file-image/<sid>/<uuid>/<i>/<k>: the URL names a place in the transcript (the line, the
content block, the k-th file of the call), never a path, so the page cannot ask for a file the session did not send,
and nothing here takes a path from a request.

A reply can also show an image by writing a markdown image of a file on this machine in its text:
![caption](/abs/path/mock.png) or ![caption](~/path/mock.png). transcript.py gives each such image of an assistant text
block a URL, GET /api/md-image/<sid>/<uuid>/<i>/<n> (the line, the block, the n-th local image of that text, counted by
md_image_paths, code blocks and spans left out); the route re-reads the text from the transcript and serves the n-th
path under the rules below, so a crafted URL reaches no file a reply did not name. There a refusal carries its reason
(check_image), which the page shows in place of the image.

What is served is decided here, from the path the transcript names:

  - the extension is png, jpg, jpeg, gif or webp, and the first bytes are that kind of image (the type sent is the
    sniffed one; svg and anything else is refused: an svg can run script)
  - the real path (symlinks resolved) is inside an allowed root: the home directory, and the session scratch directory
    /tmp/claude-<uid> that Claude Code writes into; and no component under the root starts with a dot (~/.ssh,
    ~/.config, ~/.claude, ~/.local/state and the like are never served) or names a token, secret, credential, password,
    key or certificate
  - a regular file of at most MAX_BYTES
"""

from __future__ import annotations

import os
import re
from pathlib import Path

TOOL_NAME = "SendUserFile"
EXTENSIONS = (".png", ".jpg", ".jpeg", ".gif", ".webp")
MAX_BYTES = 15 * 1024 * 1024
# a component naming something secret is refused even in an image's path; matched on the lowercased name
SECRET_NAME_RE = re.compile(r"token|secret|credential|passw|private|apikey|api-key|api_key|admin-key|\.pem|\.key|id_rsa|id_ed25519")


def default_roots() -> list[Path]:
    return [Path.home(), Path(f"/tmp/claude-{os.getuid()}")]


def media_type(head: bytes) -> str | None:
    """The image type of the first bytes of a file, or None when it is not one of the four served."""
    if head.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if head.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if head.startswith((b"GIF87a", b"GIF89a")):
        return "image/gif"
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return "image/webp"
    return None


def raw_path(item: object) -> str | None:
    """The path of one entry of SendUserFile's files: a string, or an object holding one."""
    if isinstance(item, dict):
        item = item.get("path") or item.get("file_path")
    return item if isinstance(item, str) and item.strip() else None


def is_image_name(raw: str) -> bool:
    return raw.strip().lower().endswith(EXTENSIONS)


def _hidden_or_secret(parts: tuple[str, ...]) -> bool:
    return any(p.startswith(".") or SECRET_NAME_RE.search(p.lower()) for p in parts)


def _inside(real: Path, roots: list[Path]) -> Path | None:
    """The root that real is inside, only when the part below it is neither hidden nor secret."""
    for root in roots:
        try:
            candidates = {root, root.resolve()}  # the root as named and as it really is (a home that is a link)
        except (OSError, RuntimeError):
            continue
        for r in candidates:
            try:
                rel = real.relative_to(r)
            except ValueError:
                continue
            if rel.parts and not _hidden_or_secret(rel.parts):
                return r
    return None


def check_image(raw: str, cwd: str, roots: list[Path], max_bytes: int = MAX_BYTES) -> tuple[str, bytes] | str:
    """(media type, bytes) of the image file a path names, or, when it is not served, the reason in a few words (the
    markdown-image route shows it to the owner; the SendUserFile route says only "no image"). A relative path is read
    against the session's working directory."""
    raw = raw.strip()
    if "\x00" in raw:
        return "not a file path"
    if not is_image_name(raw):
        return "not a png, jpeg, gif or webp image"
    p = Path(os.path.expanduser(raw))
    if not p.is_absolute():
        if not cwd:
            return "not an absolute path"
        p = Path(cwd) / p
    lexical = Path(os.path.normpath(p))
    try:
        real = lexical.resolve(strict=True)
    except (OSError, RuntimeError):
        return "file not found"
    # both the path as named and where it really leads must be inside a root and clean: a link in an allowed place
    # to ~/.ssh, or a name that looks harmless over a hidden directory, is refused
    for where in (lexical, real):
        if _inside(where, roots) is None:
            return _why_outside(where, roots)
    if not is_image_name(real.name):
        return "not a png, jpeg, gif or webp image"
    try:
        with real.open("rb") as f:
            st = os.fstat(f.fileno())
            if not (st.st_mode & 0o170000 == 0o100000):  # a regular file only
                return "not a regular file"
            if st.st_size > max_bytes:
                return "file too large"
            data = f.read(max_bytes + 1)
    except OSError:
        return "file cannot be read"
    if len(data) > max_bytes:
        return "file too large"
    mt = media_type(data[:16])
    if mt is None:
        return "not a png, jpeg, gif or webp image"
    return mt, data


def _why_outside(path: Path, roots: list[Path]) -> str:
    """Why a path is not inside a root with a clean remainder: it is under a root but hidden or secret-named, or elsewhere."""
    for root in roots:
        try:
            candidates = {root, root.resolve()}
        except (OSError, RuntimeError):
            continue
        for r in candidates:
            try:
                path.relative_to(r)
            except ValueError:
                continue
            return "inside a hidden or secret-named folder"
    return "outside the folders that can be shown"


def read_sent_image(raw: str, cwd: str, roots: list[Path], max_bytes: int = MAX_BYTES) -> tuple[str, bytes] | None:
    """(media type, bytes) of the image file a SendUserFile call named, or None when it is not served (every refusal
    looks the same from outside: no such image)."""
    got = check_image(raw, cwd, roots, max_bytes)
    return got if isinstance(got, tuple) else None


# ---- images a reply names in its markdown: ![caption](/abs/path.png) or ![caption](~/path.png) ----

_FENCE_RE = re.compile(r"^ {0,3}(`{3,}|~{3,})")
_CODE_SPAN_RE = re.compile(r"(`+)(?:(?!\1).)+?\1", re.S)
_MD_IMAGE_RE = re.compile(
    r"!\[(?:[^\]\\\n]|\\.)*\]\(\s*(<[^<>\n]*>|[^\s()<>]*(?:\([^\s()]*\)[^\s()]*)*)"
    r"(?:\s+(?:\"[^\"\n]*\"|'[^'\n]*'))?\s*\)")


def _outside_code(text: str) -> str:
    """The reply text without its fenced code blocks and inline code spans: markdown draws no image from those."""
    keep: list[str] = []
    fence: str | None = None
    for line in text.split("\n"):
        m = _FENCE_RE.match(line)
        if fence:
            if m and m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence) and not line[m.end():].strip():
                fence = None
            continue
        if m:
            fence = m.group(1)
            continue
        keep.append(line)
    return _CODE_SPAN_RE.sub(" ", "\n".join(keep))


def is_local_ref(dest: str) -> bool:
    """A markdown image destination that names a file on this machine: an absolute path or ~/…, not a URL (http, data, a
    protocol-relative //host) and not a path relative to the page."""
    return (dest.startswith("/") and not dest.startswith("//")) or dest.startswith("~/")


def md_image_paths(text: str) -> list[str]:
    """The local-file destinations of the markdown images in a reply's text, in order, as written (outside code).
    The route and the transcript parser both count them with this function, so the n-th one means the same thing."""
    out = []
    for m in _MD_IMAGE_RE.finditer(_outside_code(text)):
        dest = m.group(1)
        if dest.startswith("<") and dest.endswith(">"):
            dest = dest[1:-1]
        dest = dest.strip()
        if is_local_ref(dest):
            out.append(dest)
    return out
