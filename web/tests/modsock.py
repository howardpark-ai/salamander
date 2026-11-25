"""A stand-in for sala's in-session mod, for the tests of modbox.py and of the send path (like tests/mod.sh's fake mod, in Python).

`FakeMod` is what a pane's claude is to sala: a messaging socket that takes one JSON line per request
({"type":"user","message":{"role":"user","content":"[sala-mod] draft <reqid>\\n..."}}), a registry row naming the socket, and the mod's
presence stamp. Its answer to a `draft` request is set by `text` (the box's text), or `mode`:
    "ok"       reply {"reqid", "ok": true, "text": text}, written whole under a temp name and renamed, as the mod does
    "silent"   no reply at all
    "refused"  reply {"reqid", "ok": false, "reason": "error"}
    "badjson"  a reply file that is not JSON
    "late"     the reply comes after `delay` seconds

A `fill` request is answered from a small model of the CLI's prompt box (`text` is the draft: what `draft` returns and `fill` changes),
set by `fill_mode`: "unknown" (the default: a mod older than the verb, which answers `unknown`, so a test of the older send path
keeps its meaning), "ok", "silent", "badjson", "notfilled" (the box refuses without a reason), "altered" (the box holds something
else than it was given), "chip" (a long text comes back as a pasted-text chip); `dialog=True` makes it refuse with `refusal: "dialog"`
and leave the draft alone, as the CLI does under a typed dialog or the permission dialog. The box takes a text as the CLI does
(zero-width characters, NUL, BEL and ESC dropped, CRLF to LF). `watch_enter(path)` follows a file the fake pane writes its keys to:
each Enter in it submits the draft (`submitted`, trailing whitespace dropped as the CLI does) and empties the box, unless
`swallow=True` (an overlay took the Enter: the draft stays). `fills` is every (text, mode) the mod was asked to put in the box.

Everything lives in one short folder under the system temp (a unix socket's path is limited to about 100 characters, which pytest's
own folders can pass), which is locked while the fake runs and removed on close (a `with` block or `close()`).
"""

from __future__ import annotations

import fcntl
import json
import os
import shutil
import socket
import tempfile
import threading
import time
from pathlib import Path


class FakeMod:
    def __init__(self, pid: int, claude_dir: Path, session_id: str = "bbbbbbbb-0000-0000-0000-000000000000",
                 text: str = "", mode: str = "ok", delay: float = 0.0, stamp: bool = True, stamp_at_ms: int | None = None,
                 version: int = 1, run_dir: Path | None = None, row: bool = True, row_extra: dict | None = None,
                 fill_mode: str = "unknown", dialog: bool = False, swallow: bool = False):
        self.pid, self.session_id, self.text, self.mode, self.delay = pid, session_id, text, mode, delay
        self.fill_mode, self.dialog, self.swallow = fill_mode, dialog, swallow
        self.lines: list[str] = []
        self.fills: list[tuple[str, str]] = []
        self.submitted: list[str] = []
        self.enters = 0
        self.root = Path(tempfile.mkdtemp(prefix="salaweb-fakemod-"))
        self._lock = os.open(self.root, os.O_RDONLY)
        fcntl.flock(self._lock, fcntl.LOCK_EX | fcntl.LOCK_NB)   # systemd-tmpfiles' ageing leaves a locked folder alone
        self.run_dir = run_dir or self.root / "run" / "sala" / "mod"
        self.run_dir.mkdir(parents=True, exist_ok=True)
        self.sock_path = str(self.root / "c.sock")
        self._srv = socket.socket(socket.AF_UNIX)
        self._srv.bind(self.sock_path)
        self._srv.listen(8)
        self._stop = False
        self._threads: list[threading.Thread] = []
        t = threading.Thread(target=self._accept, daemon=True)
        t.start()
        self._threads.append(t)
        if row:
            rec = {"pid": pid, "sessionId": session_id, "cwd": "/tmp", "name": f"s{pid}", "status": "idle",
                   "messagingSocketPath": self.sock_path, **(row_extra or {})}
            (claude_dir / "sessions" / f"{pid}.json").write_text(json.dumps(rec))
        if stamp:
            at = int(time.time() * 1000) if stamp_at_ms is None else stamp_at_ms
            (self.run_dir / f"{session_id}.json").write_text(
                json.dumps({"present": True, "version": version, "sessionId": session_id, "at": at}) + "\n")

    def _accept(self) -> None:
        self._srv.settimeout(0.1)
        while not self._stop:
            try:
                conn, _ = self._srv.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            t = threading.Thread(target=self._serve, args=(conn,), daemon=True)
            t.start()
            self._threads.append(t)

    def _serve(self, conn: socket.socket) -> None:
        try:
            conn.settimeout(2)
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = conn.recv(65536)
                if not chunk:
                    break
                buf += chunk
        except OSError:
            return
        finally:
            conn.close()
        try:
            content = json.loads(buf)["message"]["content"]
        except (ValueError, KeyError, TypeError):
            return
        self.lines.append(content)
        first = content.split("\n")[0]
        if first.startswith("[sala-mod] fill "):
            self._fill(first.split(" ")[2])
            return
        if not first.startswith("[sala-mod] draft "):
            return
        reqid = first.split(" ")[2]
        if self.mode == "silent":
            return
        if self.mode == "late":
            time.sleep(self.delay)
        path = self.run_dir / f"{self.session_id}.{reqid}.reply.json"
        tmp = path.with_name(path.name + ".tmp-x")
        if self.mode == "badjson":
            body = "{not json"
        elif self.mode == "refused":
            body = json.dumps({"reqid": reqid, "ok": False, "reason": "error"}) + "\n"
        else:
            body = json.dumps({"reqid": reqid, "ok": True, "text": self.text}) + "\n"
        if self._stop:
            return
        tmp.write_text(body)
        os.replace(tmp, path)

    @staticmethod
    def cli_box(text: str) -> str:
        """What the CLI's prompt box keeps of a text it is given."""
        t = text.replace("\r\n", "\n")
        return "".join(c for c in t if c not in "\u200b\x00\x07\x1b")

    def _fill(self, reqid: str) -> None:
        payload = self.run_dir / f"{self.session_id}.{reqid}.fill.json"
        try:
            want = json.loads(payload.read_text(encoding="utf-8"))
            payload.unlink(missing_ok=True)     # the mod removes the payload after reading it
        except (OSError, ValueError):
            want = None
        path = self.run_dir / f"{self.session_id}.{reqid}.reply.json"
        tmp = path.with_name(path.name + ".tmp-x")
        if self.fill_mode == "silent":
            return
        if self.fill_mode == "badjson":
            body = "{not json"
        elif self.fill_mode == "unknown" or want is None:
            body = json.dumps({"reqid": reqid, "ok": False, "reason": "unknown" if self.fill_mode == "unknown" else "payload"}) + "\n"
        else:
            text, mode = want["text"], want.get("mode", "replace")
            self.fills.append((text, mode))
            refusal = "dialog" if self.dialog else None
            filled = refusal is None and (self.fill_mode != "notfilled" or not text)
            if filled:
                box = self.cli_box(text)
                if self.fill_mode == "chip" and box.count("\n") >= 3:
                    box = "[Pasted text #1 +%d lines]" % (box.count("\n") + 1)
                if self.fill_mode == "altered" and box:
                    box = box[:-1] + "?"
                if mode == "replace":
                    self.text = box
                else:
                    self.text += box
            body = json.dumps({"reqid": reqid, "ok": True, "isFilled": filled, **({"refusal": refusal} if refusal else {}),
                               "text": self.text, "cursor": len(self.text)}) + "\n"
        if self._stop:
            return
        tmp.write_text(body)
        os.replace(tmp, path)

    def watch_enter(self, path: Path) -> None:
        """Follow the keys the fake pane records in `path`: each newline byte is an Enter (the pane's tty turns the CR into LF); a test that pastes does not watch."""
        def run() -> None:
            seen = 0
            while not self._stop:
                try:
                    raw = path.read_bytes()
                except OSError:
                    raw = b""
                for _ in range(raw[seen:].count(b"\n")):
                    self.enters += 1
                    if not self.swallow:
                        self.submitted.append(self.text.rstrip())
                        self.text = ""
                seen = len(raw)
                time.sleep(0.02)
        t = threading.Thread(target=run, daemon=True)
        t.start()
        self._threads.append(t)

    @property
    def requests(self) -> int:
        return sum(1 for ln in self.lines if ln.startswith("[sala-mod] draft "))

    @property
    def fill_requests(self) -> int:
        return sum(1 for ln in self.lines if ln.startswith("[sala-mod] fill "))

    def replies_left(self) -> list[str]:
        return sorted(p.name for p in self.run_dir.glob("*.reply.json*"))

    def close(self) -> None:
        self._stop = True
        try:
            self._srv.close()
        except OSError:
            pass
        for t in self._threads:
            t.join(timeout=3)
        try:
            os.close(self._lock)
        except OSError:
            pass
        shutil.rmtree(self.root, ignore_errors=True)

    def __enter__(self) -> "FakeMod":
        return self

    def __exit__(self, *exc) -> None:
        self.close()
