"""Read and parse Claude Code transcripts (~/.claude/projects/<slug>/<sessionId>.jsonl).

A transcript line is one JSON object. Only `user` and `assistant` lines with a `message` are shown; meta lines
(isMeta), sidechains, compact summaries and every other type (attachment, system, summary, file-history-snapshot,
...) are skipped. System reminders are cut out of user text.

Transcripts reach 100+ MB, so the initial load reads backwards from the end.
"""

from __future__ import annotations

import base64
import json
import re
from datetime import datetime
from pathlib import Path

from . import sentimages as SI

UUID_RE = re.compile(r"^[0-9a-fA-F-]{8,64}$")
REMINDER_RE = re.compile(r"<system-reminder>.*?</system-reminder>", re.S)
TAG_RE = re.compile(r"^\s*<([a-z][a-z0-9-]*)>", re.S)
# Claude Code wraps text pasted into its prompt as <pasted_content id="a1">...</pasted_content id="a1">; the words
# are the owner's own, so the wrapper goes and the text stays
PASTED_RE = re.compile(r'</?pasted_content(?:\s+id="[^"]*")?\s*>')
# The record of a `!` command's output: <bash-stdout>…</bash-stdout><bash-stderr>…</bash-stderr>. Greedy, and anchored on the
# other stream's tag, so an output that holds the closing tag as text (grep -r bash-stdout) is not cut short and the
# stderr is not read twice.
BASH_BOTH_RE = re.compile(r"^\s*<bash-stdout>(.*)</bash-stdout>\s*<bash-stderr>(.*)</bash-stderr>\s*$", re.S)
BASH_OUT_RE = re.compile(r"^\s*<bash-stdout>(.*)</bash-stdout>\s*$", re.S)
BASH_ERR_RE = re.compile(r"^\s*<bash-stderr>(.*)</bash-stderr>\s*$", re.S)
BASH_TAGS_RE = re.compile(r"</?bash-(?:stdout|stderr)>")


def _bash_output(text: str) -> str:
    """The text of a `!` output record: the stdout, then the stderr. A record whose tags are empty or unmatched (an opening
    tag with no close) shows what text there is once the tags are taken off, never an empty box over output."""
    for rx in (BASH_BOTH_RE, BASH_OUT_RE, BASH_ERR_RE):
        m = rx.match(text)
        if m:
            parts = [g.strip() for g in m.groups() if g.strip()]
            if parts:
                return "\n".join(parts)
    return BASH_TAGS_RE.sub("", text).strip()

TEXT_LIMIT = 20_000
INPUT_LIMIT = 4_000
CHUNK = 1 << 20


def project_slug(cwd: str) -> str:
    """The CLI's project directory name: every non-alphanumeric character becomes '-'.

    Checked against real directories: /home/alex/.cache/lane-test -> -home-alex--cache-lane-test.
    """
    return re.sub(r"[^A-Za-z0-9]", "-", cwd)


def transcript_path(projects_dir: Path, cwd: str, session_id: str) -> Path | None:
    if not session_id or not UUID_RE.match(session_id):
        return None
    p = projects_dir / project_slug(cwd) / f"{session_id}.jsonl"
    if p.is_file():
        return p
    hits = sorted(projects_dir.glob(f"*/{session_id}.jsonl"), key=lambda x: x.stat().st_mtime, reverse=True)
    return hits[0] if hits else None


def _clip(s: str, n: int) -> tuple[str, bool]:
    return (s, False) if len(s) <= n else (s[:n], True)


def _tag_inner(text: str, tag: str) -> str:
    m = re.search(rf"<{tag}>(.*?)</{tag}>", text, re.S)
    return m.group(1).strip() if m else ""


def _user_text_block(text: str) -> dict | None:
    """Classify a user text: plain prompt, slash command, command output, or a notice. None = nothing to show."""
    text = PASTED_RE.sub("", REMINDER_RE.sub("", text)).strip()
    if not text:
        return None
    m = TAG_RE.match(text)
    tag = m.group(1) if m else None
    if tag in ("command-name", "command-message"):
        name = _tag_inner(text, "command-name") or _tag_inner(text, "command-message")
        args = _tag_inner(text, "command-args")
        return {"kind": "command", "text": f"{name} {args}".strip()}
    if tag in ("bash-stdout", "bash-stderr"):
        # the output of a `!` command: shown open under its "! <cmd>" line, not folded. One record holds both
        # tags (<bash-stdout>…</bash-stdout><bash-stderr>…</bash-stderr>); the text is the stdout, then the stderr
        body, cut = _clip(_bash_output(text), TEXT_LIMIT)
        return {"kind": "bang_output", "label": "command output", "text": body, "truncated": cut}
    if tag in ("local-command-stdout", "local-command-stderr"):
        # a slash command's output stays a folded notice
        body, cut = _clip(_tag_inner(text, tag) or text, TEXT_LIMIT)
        return {"kind": "notice", "label": "command output", "text": body, "truncated": cut}
    if tag == "bash-input":
        return {"kind": "command", "text": "! " + _tag_inner(text, "bash-input")}
    if tag == "task-notification":
        body, cut = _clip(text, TEXT_LIMIT)
        summary = _tag_inner(text, "summary") or _tag_inner(text, "status") or "task notification"
        return {"kind": "notice", "label": summary[:160], "text": body, "truncated": cut}
    if tag and tag not in ("p", "b", "i"):
        # some other machine-generated wrapper: show folded, not as the owner's words
        body, cut = _clip(text, TEXT_LIMIT)
        return {"kind": "notice", "label": tag, "text": body, "truncated": cut}
    body, cut = _clip(text, TEXT_LIMIT)
    return {"kind": "text", "text": body, "truncated": cut}


def tool_summary(name: str, inp: object) -> str:
    if not isinstance(inp, dict):
        return ""
    for key in ("description", "command", "file_path", "path", "pattern", "url", "query", "prompt", "skill",
                "subagent_type", "action"):
        v = inp.get(key)
        if isinstance(v, str) and v.strip():
            return " ".join(v.split())[:140]
    for v in inp.values():
        if isinstance(v, str) and v.strip():
            return " ".join(v.split())[:140]
    return ""


def _image_url(session_id: str, uuid: str, i: int, j: int = -1) -> str:
    return f"api/image/{session_id}/{uuid}/{i}/{j}"


def _sent_image_blocks(b: dict, session_id: str, uuid: str, i: int) -> list[dict]:
    """The images among the files of a SendUserFile call: one block each, shown inline in the reply (the files of any
    other kind stay in the tool call). The URL names the call (line, block, k-th file), never the path (sentimages.py)."""
    inp = b.get("input")
    files = inp.get("files") if isinstance(inp, dict) else None
    if not isinstance(files, list):
        return []
    caption = inp.get("caption")
    out = []
    for k, item in enumerate(files):
        raw = SI.raw_path(item)
        if raw and SI.is_image_name(raw):
            out.append({"kind": "file_image", "url": f"api/file-image/{session_id}/{uuid}/{i}/{k}",
                        "name": raw.replace("\\", "/").rsplit("/", 1)[-1][:120],
                        "caption": " ".join(caption.split())[:300] if isinstance(caption, str) and not out else ""})
    return out


PEER_PREFIX = "Another Claude session sent a message:"


PEER_TAG_RE = re.compile(r"<cross-session-message\b([^>]*)>")
PEER_HEADER_FROM_RE = re.compile(r"from: *(\S+)")
PEER_HEADER_NOTE_RE = re.compile(r"\[[^\]\n]+\] from ([A-Za-z0-9_.-]+)")


def _peer_attr(attrs: str, name: str) -> str:
    m = re.search(r'(?:^|\s)' + re.escape(name) + r'="([^"\n]*)"', attrs)
    return m.group(1).strip() if m else ""


def _peer_sender(body: str) -> str:
    """Who a peer message is from, read only from where the sender is named, never from the message's own words
    (a body saying "taken over from here" once gave the pill "message from here"). Three forms: the wrapper tag
    `<cross-session-message from="uds:..." from-name="NAME">` (its opening tag only; `from-name`, else `from` unless that
    is only a socket address); a `from: NAME` header line; a `[stackshot message] from NAME ·` header line. The two
    header forms are read from the first two lines of the message only. Empty when none names a sender."""
    tag = PEER_TAG_RE.match(body)
    if tag:
        name = _peer_attr(tag.group(1), "from-name")
        if not name:
            name = _peer_attr(tag.group(1), "from")
            if name.startswith("uds:"):
                name = ""
        return name
    for ln in body.split("\n", 2)[:2]:
        ln = ln.strip()
        m = PEER_HEADER_FROM_RE.match(ln) or PEER_HEADER_NOTE_RE.match(ln)
        if m:
            return m.group(1)
    return ""


def _meta_notice(text: str) -> dict | None:
    """A meta (machine-injected) user text worth showing: a message from another session. Everything else meta
    (hook feedback, skill bodies, caveats) is skipped."""
    text = REMINDER_RE.sub("", text).strip()
    if not text.startswith(PEER_PREFIX):
        return None
    body = text[len(PEER_PREFIX):].strip()
    sender = _peer_sender(body)
    label = f"message from {sender}" if sender else "message from another session"
    body, cut = _clip(body, TEXT_LIMIT)
    return {"kind": "notice", "label": label, "text": body, "truncated": cut}


def _meta_blocks(content: object) -> list[dict]:
    texts = [content] if isinstance(content, str) else [
        b.get("text") or "" for b in content if isinstance(b, dict) and b.get("type") == "text"
    ] if isinstance(content, list) else []
    blk = _meta_notice("\n".join(texts))
    return [blk] if blk else []


def never_shown(d: dict, subagent: bool = False) -> bool:
    """True for a transcript line the chat never shows, whatever its type: a sidechain line (a subagent's, unless this is the
    subagent's own file: `subagent`), a compaction summary, a line only the CLI's transcript view shows. parse_line skips these, and
    Search (search.entries) skips the same ones through this function, so a result is always an entry the chat can open at."""
    return bool((d.get("isSidechain") and not subagent) or d.get("isCompactSummary") or d.get("isVisibleInTranscriptOnly"))


def parse_line(d: dict, session_id: str) -> dict | None:
    """One transcript line -> one display message, or None to skip it."""
    t = d.get("type")
    if never_shown(d):
        return None
    uuid = d.get("uuid") or ""
    if t == "attachment":
        # A prompt typed while the session was busy is recorded as a queued_command attachment, not a user line.
        a = d.get("attachment") or {}
        if a.get("type") != "queued_command":
            return None
        prompt = a.get("prompt")
        if a.get("isMeta"):
            blocks = _meta_blocks(prompt)
        elif a.get("commandMode") == "task-notification":
            blocks = [b for b in [_user_text_block(prompt if isinstance(prompt, str) else "")] if b]
            for b in blocks:
                if b["kind"] == "text":
                    b.update(kind="notice", label="task notification")
        else:
            blocks = _content_blocks("user", prompt, session_id, uuid)
        return {"uuid": uuid, "role": "user", "ts": d.get("timestamp"), "blocks": blocks} if blocks else None
    if t not in ("user", "assistant"):
        return None
    msg = d.get("message")
    if not isinstance(msg, dict):
        return None
    if d.get("isMeta"):
        if t != "user":
            return None
        blocks = _meta_blocks(msg.get("content"))
        return {"uuid": uuid, "role": "user", "ts": d.get("timestamp"), "blocks": blocks} if blocks else None
    blocks = _content_blocks(t, msg.get("content"), session_id, uuid)
    if not blocks:
        return None
    out = {"uuid": uuid, "role": t, "ts": d.get("timestamp"), "blocks": blocks}
    if t == "assistant":  # the model and effort that wrote this reply, for the composer's indicator
        out.update(_model_effort(d))
    return out


def _model_effort(d: dict) -> dict:
    """{"model", "effort"} of an assistant line, each only when present; a non-Claude model (<synthetic>) is left out."""
    out = {}
    msg = d.get("message") if isinstance(d.get("message"), dict) else {}
    model = msg.get("model")
    if isinstance(model, str) and model.startswith("claude-"):
        out["model"] = model
    effort = d.get("perTurnEffort") or d.get("effort")
    if isinstance(effort, str) and effort:
        out["effort"] = effort
    return out


NARRATION = "narration"


def _pb_field(buf: bytes, want: int) -> bytes | None:
    """The last length-delimited field number `want` of a protobuf message; None when absent or when the bytes are not
    well-formed (Claude Code's own reader gives up on the whole message in that case, so does this)."""
    i, n, out = 0, len(buf), None
    while i < n:
        key = 0
        for shift in range(0, 70, 7):  # a varint
            if i >= n:
                return None
            c = buf[i]
            i += 1
            key |= (c & 0x7F) << shift
            if not c & 0x80:
                break
        else:
            return None
        wire, num = key & 7, key >> 3
        if wire in (0, 2):  # varint value, or the length of a bytes field
            val = 0
            for shift in range(0, 70, 7):
                if i >= n:
                    return None
                c = buf[i]
                i += 1
                val |= (c & 0x7F) << shift
                if not c & 0x80:
                    break
            else:
                return None
            if wire == 2:
                if val > n - i:
                    return None
                if num == want:
                    out = buf[i:i + val]
                i += val
        elif wire == 1:
            i += 8
        elif wire == 5:
            i += 4
        else:
            return None
        if i > n:
            return None
    return out


def signature_kind(sig: object) -> str | None:
    """What the API labelled a `thinking` block, read from its signature the way Claude Code does: the
    signature is base64 of a protobuf whose field 2 holds a message whose field 1 holds a message whose field 8 is a
    string: "thinking" for real (hidden) thinking, "narration" for model text sent as thinking. None when unreadable."""
    if not isinstance(sig, str) or not sig:
        return None
    try:
        raw = base64.b64decode(sig + "=" * (-len(sig) % 4))
        outer = _pb_field(raw, 2)
        inner = _pb_field(outer, 1) if outer is not None else None
        kind = _pb_field(inner, 8) if inner is not None else None
        return kind.decode("utf-8") if kind is not None else None
    except (ValueError, UnicodeDecodeError):
        return None


def _content_blocks(t: str, content: object, session_id: str, uuid: str) -> list[dict]:
    blocks: list[dict] = []
    if isinstance(content, str):
        content = [{"type": "text", "text": content}]
    if not isinstance(content, list):
        return blocks
    for i, b in enumerate(content):
        if not isinstance(b, dict):
            continue
        bt = b.get("type")
        if bt == "text":
            if t == "user":
                blk = _user_text_block(b.get("text") or "")
                if blk:
                    blocks.append(blk)
            else:
                txt = (b.get("text") or "").strip()
                if txt:
                    body, cut = _clip(txt, TEXT_LIMIT * 5)
                    blk = {"kind": "text", "text": body, "truncated": cut}
                    refs = SI.md_image_paths(body)
                    if refs:  # markdown images of files on this machine: each is served by its place in this block
                        blk["localImages"] = [{"src": r, "url": f"api/md-image/{session_id}/{uuid}/{i}/{n}"}
                                              for n, r in enumerate(refs)]
                    blocks.append(blk)
        elif bt == "thinking":
            txt = (b.get("thinking") or "").strip()
            if txt and t == "assistant" and signature_kind(b.get("signature")) == NARRATION:
                # narration: model text the API labels `thinking`; Claude Code prints it as a reply line, so a reply here
                body, cut = _clip(txt, TEXT_LIMIT * 5)
                blocks.append({"kind": "text", "text": body, "truncated": cut})
            elif txt:
                blocks.append({"kind": "thinking", "text": txt})
        elif bt in ("tool_use", "server_tool_use"):
            inp = b.get("input")
            try:
                js = json.dumps(inp, ensure_ascii=False, indent=2)
            except (TypeError, ValueError):
                js = str(inp)
            js, cut = _clip(js, INPUT_LIMIT)
            blocks.append({"kind": "tool_use", "id": b.get("id"), "name": b.get("name") or "tool",
                           "summary": tool_summary(b.get("name") or "", inp), "input": js, "truncated": cut})
            if t == "assistant" and b.get("name") == SI.TOOL_NAME:
                blocks.extend(_sent_image_blocks(b, session_id, uuid, i))
        elif isinstance(bt, str) and (bt == "tool_result" or bt.endswith("_tool_result")):
            c = b.get("content")
            texts: list[str] = []
            images: list[str] = []
            if isinstance(c, str):
                texts.append(c)
            elif isinstance(c, list):
                for j, sub in enumerate(c):
                    if not isinstance(sub, dict):
                        continue
                    if sub.get("type") == "text":
                        texts.append(sub.get("text") or "")
                    elif sub.get("type") == "image":
                        images.append(_image_url(session_id, uuid, i, j))
                    elif sub.get("type") == "tool_reference":
                        texts.append(f"[tool reference: {sub.get('tool_name') or sub.get('name') or ''}]")
            body, cut = _clip("\n".join(texts), TEXT_LIMIT)
            blocks.append({"kind": "tool_result", "toolUseId": b.get("tool_use_id"), "text": body,
                           "truncated": cut, "isError": bool(b.get("is_error")), "images": images})
        elif bt == "image":
            blocks.append({"kind": "image", "url": _image_url(session_id, uuid, i)})
    return blocks


def _parse_raw(line: bytes, session_id: str) -> dict | None:
    if b'"message"' not in line and b'"queued_command"' not in line:
        return None
    try:
        d = json.loads(line)
    except ValueError:
        return None
    return parse_line(d, session_id) if isinstance(d, dict) else None


def complete_end(path: Path) -> int:
    """Offset just past the last newline (a line still being written is left for the next read)."""
    size = path.stat().st_size
    with path.open("rb") as f:
        pos = size
        while pos > 0:
            start = max(0, pos - 65536)
            f.seek(start)
            chunk = f.read(pos - start)
            k = chunk.rfind(b"\n")
            if k >= 0:
                return start + k + 1
            pos = start
    return 0


def _read_back(path: Path, session_id: str, end: int, n: int, max_bytes: int) -> tuple[list[dict], int]:
    """Up to n display messages in the complete lines that end at or before byte `end`, read backwards in CHUNK-sized
    reads (a large file is never read whole), and the cursor: the offset of the first line read (every line from it to
    `end` was looked at). Gives up after max_bytes; the cursor then says where to go on from."""
    out_rev: list[dict] = []
    cursor = end
    with path.open("rb") as f:
        pos = end
        leftover = b""
        while pos > 0 and len(out_rev) < n and end - pos < max_bytes:
            start = max(0, pos - CHUNK)
            f.seek(start)
            data = f.read(pos - start) + leftover
            pos = start
            lines = data.split(b"\n")
            if pos > 0:
                leftover, lines = lines[0], lines[1:]
            else:
                leftover = b""
            # data covers [start, start + len(data)); lines[0] (when kept) begins at start + len(leftover) + 1
            cur = start + len(data)
            for line in reversed(lines):
                line_start = cur - len(line)
                cur = line_start - 1  # the newline before it
                cursor = line_start
                if not line.strip():
                    continue
                m = _parse_raw(line, session_id)
                if m:
                    out_rev.append(m)
                    if len(out_rev) >= n:
                        break
    out_rev.reverse()
    return out_rev, cursor


def read_tail(path: Path, session_id: str, n: int = 200, max_bytes: int = 64 << 20) -> tuple[list[dict], int]:
    """The last n display messages and the offset reading stopped at (to tail from)."""
    msgs, _cursor, end = read_tail_page(path, session_id, n, max_bytes)
    return msgs, end


def read_tail_page(path: Path, session_id: str, n: int = 200, max_bytes: int = 64 << 20) -> tuple[list[dict], int, int]:
    """read_tail with the cursor for read_before: (messages, cursor, end). cursor == 0: the file's start was reached."""
    end = complete_end(path)
    msgs, cursor = _read_back(path, session_id, end, n, max_bytes)
    return msgs, cursor, end


class BadCursor(ValueError):
    pass


def check_cursor(path: Path, before: object) -> int:
    """A `before` cursor from a page, as an int: 0 <= before <= the end of the file's complete lines, and on a line's
    start (0, or just after a newline). Anything else raises BadCursor."""
    if isinstance(before, bool):
        raise BadCursor("cursor is not an integer")
    if isinstance(before, str):
        if not before.isascii() or not before.isdigit() or len(before) > 18:
            raise BadCursor("cursor is not an integer")
        before = int(before)
    if not isinstance(before, int):
        raise BadCursor("cursor is not an integer")
    if before < 0 or before > complete_end(path):
        raise BadCursor("cursor is outside the transcript")
    if before > 0:
        with path.open("rb") as f:
            f.seek(before - 1)
            if f.read(1) != b"\n":
                raise BadCursor("cursor is not at a line start")
    return before


def read_before(path: Path, session_id: str, before: object, n: int = 200,
                max_bytes: int = 64 << 20) -> tuple[list[dict], int, bool]:
    """The up-to-n display messages in the lines that end before byte `before` (a cursor from read_tail_page or an
    earlier read_before), the new cursor, and whether the file's start was reached. A bad cursor raises BadCursor."""
    end = check_cursor(path, before)
    msgs, cursor = _read_back(path, session_id, end, n, max_bytes)
    return msgs, cursor, cursor == 0


def _read_fwd(path: Path, session_id: str, start: int, n: int, max_bytes: int) -> tuple[list[dict], int, int]:
    """Up to n display messages in the complete lines from byte `start` (a line's start) on, read forwards in CHUNK-sized
    reads, the cursor: the offset just past the last line read (a line's start, every line before it was looked at), and
    the end of the file's complete lines when it was read. Gives up after max_bytes; the cursor then says where to go on
    from."""
    out: list[dict] = []
    end = complete_end(path)
    cursor = start
    with path.open("rb") as f:
        pos = start
        leftover = b""
        while pos < end and len(out) < n and cursor - start < max_bytes:
            f.seek(pos)
            data = leftover + f.read(min(CHUNK, end - pos))
            pos = f.tell()
            lines = data.split(b"\n")
            leftover = lines.pop()      # the part after the last newline: the head of a line the next read finishes
            for line in lines:
                cursor += len(line) + 1
                if line.strip():
                    m = _parse_raw(line, session_id)
                    if m:
                        out.append(m)
                        if len(out) >= n:
                            break
            else:
                continue
            break
    return out, cursor, end


def read_after(path: Path, session_id: str, after: object, n: int = 200,
               max_bytes: int = 64 << 20) -> tuple[list[dict], int, bool]:
    """The up-to-n display messages in the lines from byte `after` on (a cursor from read_around or an earlier read_after),
    the new cursor, and whether the end of the file's complete lines was reached (the chat then follows the live stream).
    A bad cursor raises BadCursor, as read_before's does."""
    start = check_cursor(path, after)
    msgs, cursor, end = _read_fwd(path, session_id, start, n, max_bytes)
    return msgs, cursor, cursor >= end


def read_around(path: Path, session_id: str, at: object, n: int = 200, max_bytes: int = 64 << 20) -> dict:
    """A page of display messages around the line that starts at byte `at` (a search result's `pos`): about half of them
    before it, the rest from it on (it first), with the cursors to page on from: `before` for read_before (older) and
    `after` for read_after (newer), `start` (the file's start is in) and `end` (the end of the file is in). A bad cursor
    raises BadCursor."""
    at = check_cursor(path, at)
    half = max(1, n // 2)
    older, before = _read_back(path, session_id, at, half, max_bytes)
    newer, after, end = _read_fwd(path, session_id, at, max(1, n - len(older)), max_bytes)
    return {"messages": older + newer, "before": before, "start": before == 0, "after": after, "end": after >= end}


def read_from(path: Path, session_id: str, offset: int) -> tuple[list[dict], int]:
    """Display messages in complete lines after offset, and the new offset."""
    out: list[dict] = []
    with path.open("rb") as f:
        f.seek(offset)
        data = f.read()
    k = data.rfind(b"\n")
    if k < 0:
        return out, offset
    for line in data[: k + 1].split(b"\n"):
        if line.strip():
            m = _parse_raw(line, session_id)
            if m:
                out.append(m)
    return out, offset + k + 1


BANG_TAIL = 256 << 10      # a running `!` command's bash-input is nearly always within the last 256 KB
BANG_TAIL_MAX = 4 << 20    # widen 4x at a time up to this; a transcript with no `!` record in it shows none running
BASH_DONE_TAGS = ("<bash-stdout>", "<bash-stderr>")


def _line_text(d: dict) -> str | None:
    """The text of a main-thread user line (its string content, or its text blocks joined); None for any other line."""
    if d.get("type") != "user" or d.get("isSidechain") or d.get("isMeta"):
        return None
    msg = d.get("message")
    content = msg.get("content") if isinstance(msg, dict) else None
    if isinstance(content, list):
        content = "\n".join(b.get("text") or "" for b in content if isinstance(b, dict) and b.get("type") == "text")
    return content if isinstance(content, str) else None


def _bang_step(d: dict) -> tuple[str, dict | None] | None:
    """What one parsed transcript line says about a `!` command: ("start", {"command", "uuid", "ts"}) for a
    <bash-input> record, ("end", None) for a <bash-stdout> / <bash-stderr> record (the command's output: Claude Code writes
    it when the command ends or times out) or for a prompt the owner typed after it (a stale start is over), None for every
    other line."""
    text = _line_text(d)
    if text is None:
        return None
    if any(t in text for t in BASH_DONE_TAGS):
        return "end", None
    if "<bash-input>" in text:
        ts = d.get("timestamp")
        return "start", {"command": _tag_inner(text, "bash-input"), "uuid": d.get("uuid") or "",
                         "ts": ts if isinstance(ts, str) else ""}
    blk = _user_text_block(text)
    return ("end", None) if blk and blk["kind"] == "text" else None


def bang_running(path: Path, first: int = BANG_TAIL, cap: int = BANG_TAIL_MAX) -> dict | None:
    """The `!` command the transcript says is running, or None: {"command", "uuid", "ts"} when the latest `!` record in
    the tail is a <bash-input> with no <bash-stdout> / <bash-stderr> record after it and no prompt of the owner's after it.
    Read from the end, so a quiet session costs one small read (Claude Code writes a `!` command's output only when the
    command ends, so until then the input record is the latest)."""
    try:
        size = path.stat().st_size
    except OSError:
        return None
    window = first
    while True:
        start = max(0, size - window)
        with path.open("rb") as f:
            f.seek(start)
            lines = f.read(size - start).split(b"\n")
        if start > 0:
            lines = lines[1:]  # cut mid-line
        for line in reversed(lines):
            if b'"user"' not in line:
                continue
            try:
                d = json.loads(line)
            except ValueError:
                continue  # the line still being written
            step = _bang_step(d) if isinstance(d, dict) else None
            if step:
                return step[1]
        if start == 0 or window >= cap:
            return None
        window = min(window * 4, cap)


def bang_scan(path: Path, start: int, end: int, prev: dict | None) -> dict | None:
    """bang_running's answer after the complete lines in [start, end) were appended, given the answer before them
    (what the stream already read, so a quiet session costs nothing and a busy one reads only its new lines)."""
    if end <= start:
        return prev
    with path.open("rb") as f:
        f.seek(start)
        data = f.read(end - start)
    for line in data.split(b"\n"):
        if b'"user"' not in line:
            continue
        try:
            d = json.loads(line)
        except ValueError:
            continue
        step = _bang_step(d) if isinstance(d, dict) else None
        if step:
            prev = step[1]
    return prev


def find_image(path: Path, uuid: str, i: int, j: int) -> tuple[str, bytes] | None:
    """The base64 image at content[i] (or content[i].content[j]) of the line with this uuid."""
    needle = f'"{uuid}"'.encode()
    with path.open("rb") as f:
        for line in f:
            if needle not in line:
                continue
            try:
                d = json.loads(line)
                if d.get("uuid") != uuid:
                    continue
                content = d["message"]["content"] if "message" in d else d["attachment"]["prompt"]
                b = content[i]
                if j >= 0:
                    b = b["content"][j]
                src = b["source"]
                if src.get("type") != "base64":
                    return None
                return src.get("media_type") or "image/png", base64.b64decode(src["data"])
            except (ValueError, KeyError, IndexError, TypeError):
                return None
    return None


def find_sent_file(path: Path, uuid: str, i: int, k: int) -> tuple[str, str] | None:
    """(the path as written, the line's working directory) of the k-th file of the SendUserFile call at content[i] of
    the line with this uuid; None when the line, the block or the file is not there."""
    needle = f'"{uuid}"'.encode()
    with path.open("rb") as f:
        for line in f:
            if needle not in line:
                continue
            try:
                d = json.loads(line)
                if d.get("uuid") != uuid:
                    continue
                b = d["message"]["content"][i]
                if b.get("type") != "tool_use" or b.get("name") != SI.TOOL_NAME:
                    return None
                raw = SI.raw_path(b["input"]["files"][k])
                cwd = d.get("cwd")
                return (raw, cwd if isinstance(cwd, str) else "") if raw else None
            except (ValueError, KeyError, IndexError, TypeError, AttributeError):
                return None
    return None


def find_md_image(path: Path, uuid: str, i: int, n: int) -> tuple[str, str] | None:
    """(the path as written, the line's working directory) of the n-th local markdown image in the text block content[i] of
    the assistant line with this uuid; None when the line, the block or the image is not there. The text is clipped as
    parse_line clips it, so n counts what the page was offered."""
    needle = f'"{uuid}"'.encode()
    with path.open("rb") as f:
        for line in f:
            if needle not in line:
                continue
            try:
                d = json.loads(line)
                if d.get("uuid") != uuid or d.get("type") != "assistant":
                    continue
                b = d["message"]["content"][i]
                if b.get("type") != "text":
                    return None
                body, _ = _clip((b.get("text") or "").strip(), TEXT_LIMIT * 5)
                refs = SI.md_image_paths(body)
                if not 0 <= n < len(refs):
                    return None
                cwd = d.get("cwd")
                return refs[n], cwd if isinstance(cwd, str) else ""
            except (ValueError, KeyError, IndexError, TypeError, AttributeError):
                return None
    return None


MODEL_TAIL = 256 << 10      # the latest reply is nearly always in the last 256 KB
MODEL_TAIL_MAX = 16 << 20   # widen 4x at a time up to this; a session with no reply in it shows no model


def latest_model(path: Path, first: int = MODEL_TAIL, cap: int = MODEL_TAIL_MAX) -> dict:
    """{"model", "effort", "ts"} of the transcript's latest main-thread assistant line with a Claude model, read from
    the tail only ("ts" is the line's timestamp, when it has one: sessions.running_model compares it with the process's
    start); {} when there is none within cap bytes of the end."""
    try:
        size = path.stat().st_size
    except OSError:
        return {}
    window = first
    with path.open("rb") as f:
        while True:
            start = max(0, size - window)
            f.seek(start)
            lines = f.read(size - start).split(b"\n")
            if start > 0:
                lines = lines[1:]  # cut mid-line
            for line in reversed(lines):
                if b'"assistant"' not in line or b'"model"' not in line:
                    continue
                try:
                    d = json.loads(line)
                except ValueError:
                    continue  # the line still being written
                if not isinstance(d, dict) or d.get("type") != "assistant" or d.get("isSidechain"):
                    continue
                got = _model_effort(d)
                if "model" in got:
                    if isinstance(d.get("timestamp"), str):
                        got["ts"] = d["timestamp"]
                    return got
            if start == 0 or window >= cap:
                return {}
            window = min(window * 4, cap)


class ModelCache:
    """latest_model per transcript, kept while the file's mtime and size are unchanged: a poll of every session
    reads only the transcripts that grew since the last one."""

    MAX_ENTRIES = 500

    def __init__(self):
        self._entries: dict[Path, tuple[int, int, dict]] = {}

    def get(self, path: Path) -> dict:
        try:
            st = path.stat()
        except OSError:
            self._entries.pop(path, None)
            return {}
        hit = self._entries.get(path)
        if hit and hit[0] == st.st_mtime_ns and hit[1] == st.st_size:
            return hit[2]
        got = latest_model(path)
        if len(self._entries) >= self.MAX_ENTRIES:
            self._entries.clear()  # sessions come and go; dropping all now and then keeps it small
        self._entries[path] = (st.st_mtime_ns, st.st_size, got)
        return got


REPLY_TAIL = 256 << 10      # the latest reply is nearly always in the last 256 KB
REPLY_TAIL_MAX = 16 << 20   # widen 4x at a time up to this; a transcript with no reply in it has none


def _iso_ms(ts: object) -> int | None:
    """An ISO-8601 timestamp ("2026-10-30T03:00:00.000Z") as epoch milliseconds; None for anything else."""
    if not isinstance(ts, str):
        return None
    try:
        return int(datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp() * 1000)
    except ValueError:
        return None


def _reply_of(d: object) -> dict | None:
    """{"uuid", "ts"} when a transcript line is a reply the owner can read: a main-thread assistant line with a non-empty text
    block (a tool call or thinking alone is not one; neither is a synthetic line, which the CLI writes for an interrupt or
    an API error), and a timestamp; else None. "ts" is epoch milliseconds."""
    if not isinstance(d, dict) or d.get("type") != "assistant" or d.get("isSidechain") or d.get("isMeta"):
        return None
    msg = d.get("message")
    if not isinstance(msg, dict) or msg.get("model") == "<synthetic>":
        return None
    content = msg.get("content")
    texts = [content] if isinstance(content, str) else [
        b.get("text") for b in content if isinstance(b, dict) and b.get("type") == "text"] if isinstance(content, list) else []
    if not any(isinstance(t, str) and t.strip() for t in texts):
        return None
    ts = _iso_ms(d.get("timestamp"))
    return {"uuid": d.get("uuid") or "", "ts": ts} if ts is not None else None


def latest_reply(path: Path, first: int = REPLY_TAIL, cap: int = REPLY_TAIL_MAX) -> dict | None:
    """The transcript's latest reply (_reply_of), read from the tail only; None when there is none within cap bytes of
    the end. The read marker is compared with it (unread.py)."""
    try:
        size = path.stat().st_size
    except OSError:
        return None
    window = first
    with path.open("rb") as f:
        while True:
            start = max(0, size - window)
            f.seek(start)
            lines = f.read(size - start).split(b"\n")
            if start > 0:
                lines = lines[1:]  # cut mid-line
            for line in reversed(lines):
                if b'"assistant"' not in line or b'"text"' not in line:
                    continue
                try:
                    d = json.loads(line)
                except ValueError:
                    continue  # the line still being written
                if (got := _reply_of(d)) is not None:
                    return got
            if start == 0 or window >= cap:
                return None
            window = min(window * 4, cap)


REPLY_COUNT_MAX = 10   # count_replies_since stops at this many: "10" means "10 or more" (the sidebar shows 9+ above 9)


def _ends_turn(d: object, strict: bool) -> dict | None:
    """_reply_of(d) when the line also ends its turn, else None. A text that is followed by a tool call in the same message
    (stop_reason "tool_use") is narration on the way to the answer, not the answer. An idle session's lines count with no
    stop_reason at all (older transcripts and the CLI's partial lines); `strict` (the session is busy or waiting) asks for
    one that is there and is not "tool_use", so the text a running turn is writing at this moment is not counted yet."""
    got = _reply_of(d)
    if got is None:
        return None
    stop = d["message"].get("stop_reason")
    if stop == "tool_use" or (strict and stop is None):
        return None
    return got


def count_replies_since(path: Path, since_ms: int, strict: bool = False, limit: int = REPLY_COUNT_MAX,
                        first: int = REPLY_TAIL, cap: int = REPLY_TAIL_MAX) -> int:
    """How many replies (_ends_turn: one per turn that ended in text) the transcript has with a timestamp after `since_ms`,
    at most `limit`. Read from the tail, newest first, and stops at the first reply that is not newer: 256 KB is nearly
    always enough, and a window is widened 4x at a time up to `cap` bytes only while every reply seen is still newer (a
    session far behind). A count that needs more than `cap` bytes of tool output to reach `limit` stops short of it; that
    is why the sidebar's 9+ is a floor, never an exact number."""
    try:
        size = path.stat().st_size
    except OSError:
        return 0
    window = first
    with path.open("rb") as f:
        while True:
            start = max(0, size - window)
            f.seek(start)
            lines = f.read(size - start).split(b"\n")
            if start > 0:
                lines = lines[1:]  # cut mid-line
            n = 0
            for line in reversed(lines):
                if b'"assistant"' not in line or b'"text"' not in line:
                    continue
                try:
                    d = json.loads(line)
                except ValueError:
                    continue  # the line still being written
                got = _ends_turn(d, strict)
                if got is None:
                    continue
                if got["ts"] <= since_ms:
                    return n   # everything older is read
                n += 1
                if n >= limit:
                    return limit
            if start == 0 or window >= cap:
                return n
            window = min(window * 4, cap)


class ReplyCache:
    """latest_reply per transcript, kept while the file's mtime and size are unchanged (ModelCache's way)."""

    MAX_ENTRIES = 500

    def __init__(self):
        self._entries: dict[Path, tuple[int, int, dict | None]] = {}
        self._counts: dict[Path, tuple[int, int, int, bool, int]] = {}   # path -> (mtime, size, since, strict, count)

    def get(self, path: Path) -> dict | None:
        try:
            st = path.stat()
        except OSError:
            self._entries.pop(path, None)
            return None
        hit = self._entries.get(path)
        if hit and hit[0] == st.st_mtime_ns and hit[1] == st.st_size:
            return hit[2]
        got = latest_reply(path)
        if len(self._entries) >= self.MAX_ENTRIES:
            self._entries.clear()
        self._entries[path] = (st.st_mtime_ns, st.st_size, got)
        return got

    def count_since(self, path: Path, since_ms: int, strict: bool = False) -> int:
        """count_replies_since, kept while the file, the marker and the strictness are unchanged: a poll every 10 s per front
        agent reads a transcript again only when it grew."""
        try:
            st = path.stat()
        except OSError:
            self._counts.pop(path, None)
            return 0
        hit = self._counts.get(path)
        if hit and hit[:4] == (st.st_mtime_ns, st.st_size, since_ms, strict):
            return hit[4]
        got = count_replies_since(path, since_ms, strict)
        if len(self._counts) >= self.MAX_ENTRIES:
            self._counts.clear()
        self._counts[path] = (st.st_mtime_ns, st.st_size, since_ms, strict, got)
        return got
