#!/usr/bin/env python3
"""gmail_fetch.py: the owner's unread mail, read and trimmed by CODE, for summary-lean.sh.

The morning summary used to let the model read Gmail itself (a full agent turn with tools). Here the code reads the mail
and the model only writes the text from what this prints. This file is the read side:

  gmail_fetch.py [--query is:unread] [--page-size 100] [--meta-file F]

stdout: the unread mail as one framed data block (<unread-mail-data ...> ... </unread-mail-data>), trimmed to a total
character cap; every item carries its Gmail thread id (the `[gmail:THREAD_ID]` marker rule needs it). --meta-file: a
JSON object with the counts the shell prints and checks (unread, threads, shown, omitted, more, reads).
Exit 0 = the mailbox was read (an empty one included); 3 = the login for the read was refused or has expired (the shell
posts the "didn't run" notice); 4 = any other failure to read. One line on stderr says why; nothing is printed on stdout.

HOW IT READS THE MAILBOX (an open question, answered; README "The lean summary"). The owner's Gmail account
(BRIEFING_GMAIL_ACCOUNT names it in the notices and links) is served by a Google Workspace MCP server behind an MCP Portal. Code reaches it the way
Claude Code does: an MCP "streamable HTTP" client for the portal's /mcp address (BRIEFING_LEAN_PORTAL_URL, else the serverUrl
of Claude Code's login entry, e.g. https://mcp-portal.example.com/mcp; neither: exit 4, nothing sent), signed with the portal's OAuth
access token that Claude Code already holds in <config dir>/.credentials.json (mcpOAuth, the entry "mcp-portal"). It calls
the portal's one tool `portal_codemode_execute` with a fixed JavaScript template per read, and only these five Gmail reads
ever go out (READS; the guard.py allow-list is applied to every code string before it is sent, so the read-only rule holds
here as it does for the model's runs): search_gmail_messages, get_gmail_message_content, get_gmail_messages_content_batch,
get_gmail_thread_content, get_gmail_threads_content_batch. Nothing else: no send, draft, label, modify, trash, no Drive or
Calendar tool, no other account.
  - The access token is read here and goes only into the Authorization header: never printed, logged, in argv or in an
    error line (every message is scrubbed of it). This code NEVER refreshes or re-authorizes: the refresh token rotates on
    every use (a second client using it would break Claude Code's login), so only Claude Code may. The access token lives
    15 minutes. When the stored one has less than 90 s left, WARM_CMD (default `claude mcp get mcp-portal`, a
    health check of that server with no model call) is run so Claude Code itself renews it, and the file is read again;
    if it is still stale the run ends with exit 3.
  - A proxy edge in front of the portal may refuse the default Python user agent (error 1010), so the requests carry their own.
  - Pagination: the portal masks the search's next-page token, so one search of --page-size messages is all there is; a
    mailbox with more unread than that is reported as `more` (the shell prints "N+").

The portal's size limit (the cause of an early run's empty digest): Code Mode cuts any answer at about
24000 characters. The message contents are therefore read 8 at a time through a fixed JavaScript template that cuts the answer
inside the portal to five headers and BODY_RAW body characters per message (BATCH_JS; the same guard.py allow-list applies), a
batch still cut is split in halves, and a run whose first five threads (or over a fifth of all) have neither subject nor sender
fails with exit 4 "Gmail came back with empty threads" instead of becoming a digest. The meta file's `empty` counts them.

Trimming (the model cannot open a thread any more, so code picks what it sends): per unread thread the newest unread
message, as From / date in the zone TZ names (BRIEFING_TZ; the owner's form, `Mon Oct 26th 14:03`, which the digest copies as given) / subject / a cleaned body (HTML to
text, quoted replies, signatures and newsletter footers cut, links dropped except for Google Alerts, which are
read out as real article title + destination URL); human mail first, then automated mail, then alerts; a few hundred
characters each, shrinking in steps until the whole block fits the cap (BRIEFING_LEAN_MAX_CHARS, default 30000); what
still does not fit is counted as omitted.

Environment (tests repoint them): BRIEFING_LEAN_CREDENTIALS (the credentials file; default
<BRIEFING_CLAUDE_CONFIG_DIR or ~/.claude>/.credentials.json), BRIEFING_LEAN_PORTAL_URL (default: the entry's serverUrl; no built-in address),
BRIEFING_LEAN_WARM_CMD, BRIEFING_LEAN_TIMEOUT (seconds for the whole fetch, default 240), BRIEFING_LEAN_MAX_CHARS.
"""
import argparse
import html
import importlib.util
import json
import os
import re
import shlex
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from html.parser import HTMLParser
from urllib.parse import parse_qs, urlparse

sys.dont_write_bytecode = True   # loading guard.py must not leave a __pycache__ in the production checkout
HERE = os.path.dirname(os.path.abspath(__file__))
# the name the fetch gives itself to the portal (MCP clientInfo) and, with /1, its User-Agent: BRIEFING_LEAN_CLIENT_NAME, which
# lib.sh exports (from the environment or the sala config); unset: sala-briefing-lean
CLIENT_NAME = os.environ.get("BRIEFING_LEAN_CLIENT_NAME") or "sala-briefing-lean"
USER_AGENT = CLIENT_NAME + "/1"
PROTOCOL = "2025-06-18"
SKEW = 90          # seconds of life the stored access token must still have
EXEC_TOOL = "mcp__mcp-portal__portal_codemode_execute"   # guard.py's name for the portal's execute tool

# the portal's Gmail reads: g<word>_<read>, <word> BRIEFING_GMAIL_CONNECTOR in lower case (guard.py's PREFIX, the same rule);
# none when it is not set, and main refuses to run
_CONNECTOR = os.environ.get("BRIEFING_GMAIL_CONNECTOR", "")
PREFIX = "g" + _CONNECTOR.lower() + "_" if re.fullmatch(r"[A-Za-z0-9]+", _CONNECTOR) else ""
READS = tuple(PREFIX + r for r in ("search_gmail_messages", "get_gmail_message_content", "get_gmail_messages_content_batch",
                                   "get_gmail_thread_content", "get_gmail_threads_content_batch")) if PREFIX else ()
FRAME_OPEN, FRAME_CLOSE = "<unread-mail-data", "</unread-mail-data>"
EXIT_AUTH, EXIT_FAIL = 3, 4


class AuthError(Exception):
    pass


class FetchError(Exception):
    pass


# --- the read-only wall -------------------------------------------------------------------------------------------

_GUARD = None


def _guard():
    global _GUARD
    if _GUARD:
        return _GUARD
    spec = importlib.util.spec_from_file_location("briefing_guard", os.path.join(HERE, "guard.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    _GUARD = mod
    return mod


# The portal's Code Mode cuts every result at about 24000 characters: a JSON string cut mid-way, then a line
# "--- TRUNCATED ---" and "Response was ~N tokens". Twenty-five full messages are 60000 characters, so a batch of that size
# arrived cut and unparseable, and every message in it came back with no sender, date, subject or body (an early run).
# So the batch read is trimmed INSIDE the portal's code (headers cut to the ones the digest
# uses, the body to BODY_RAW characters) and sent in small batches; one that still comes back cut is split in halves
# (Portal.read_messages), and a thread with nothing readable fails the run (check_readable).
BATCH_TOOL = PREFIX + "get_gmail_messages_content_batch"
BODY_RAW = 3000       # characters of each message body asked of the portal (the digest keeps 120 to 900 after cleaning)
BATCH_SIZE = 8
TRUNC_MARK = "--- TRUNCATED ---"
BATCH_JS = (r'async () => { const r = await codemode.%s(%s); '
            r'const s = typeof r === "string" ? r : (r.result || JSON.stringify(r)); '
            r'const keep = /^(Subject|From|Date|List-Unsubscribe|List-Id|Precedence|Error):/i; '
            r'return s.split("\n\nMessage ID: ").map((m, n) => { if (n === 0) return m; '
            r'const k = m.indexOf("--- BODY ---"); '
            r'const head = (k < 0 ? m : m.slice(0, k)).split("\n").filter((l, i) => i === 0 || keep.test(l)).map((l) => l.slice(0, 300)).join("\n"); '
            r'return k < 0 ? head : head + "\n\n--- BODY ---\n" + m.slice(k + 13, k + 13 + %d).replace(/\s+$/, "") + "\n"; '
            r'}).join("\n\nMessage ID: "); }')


def read_code(tool, args, body_raw=0):
    """The JavaScript for one read, checked by guard.py's allow-list before it can be sent (raises FetchError).

    body_raw > 0 (the message batch only): the template that trims the answer inside the portal to that many body characters."""
    if tool not in READS:
        raise FetchError(f"refusing a call that is not one of the five Gmail reads: {tool}")
    if body_raw:
        if tool != BATCH_TOOL:
            raise FetchError(f"only {BATCH_TOOL} has a trimming template")
        code = BATCH_JS % (tool, json.dumps(args, ensure_ascii=True), int(body_raw))
    else:
        code = "async () => await codemode.%s(%s)" % (tool, json.dumps(args, ensure_ascii=True))
    decision, reason, names = _guard().decide(EXEC_TOOL, {"code": code})
    if decision != "allow" or list(names) != [tool]:
        raise FetchError(f"the read guard refused the code for {tool}: {reason}")
    return code


# --- the portal client --------------------------------------------------------------------------------------------

class Portal:
    def __init__(self, deadline):
        self.deadline = deadline
        self.sid = None
        self.n = 0
        self.reads = 0
        self.token = ""
        self.url = ""

    # credentials (read only; never written)
    def load(self):
        cfg = os.environ.get("BRIEFING_CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
        path = os.environ.get("BRIEFING_LEAN_CREDENTIALS") or os.path.join(cfg, ".credentials.json")
        for attempt in (0, 1):   # Claude Code may be rewriting the file at this instant
            try:
                with open(path, encoding="utf-8") as f:
                    store = json.load(f).get("mcpOAuth") or {}
                break
            except (OSError, ValueError):
                if attempt:
                    raise AuthError("no readable Claude Code login file for the MCP portal")
                time.sleep(1)
        ent = next((v for k, v in store.items() if isinstance(v, dict)
                    and (k.split("|")[0] == "mcp-portal" or v.get("serverName") == "mcp-portal")), None)
        if not ent or not ent.get("accessToken"):
            raise AuthError("Claude Code holds no login for the MCP portal")
        self.token = ent["accessToken"]
        self.url = (os.environ.get("BRIEFING_LEAN_PORTAL_URL") or ent.get("serverUrl") or "").strip()
        if not self.url:   # no built-in address: nothing is sent anywhere
            raise FetchError("no MCP portal address: set BRIEFING_LEAN_PORTAL_URL (the login entry names no serverUrl)")
        exp = ent.get("expiresAt")
        return (float(exp) / 1000.0 - time.time()) if isinstance(exp, (int, float)) else None

    def ensure_fresh(self):
        left = self.load()
        if left is None or left >= SKEW:
            return
        warm = os.environ.get("BRIEFING_LEAN_WARM_CMD") or "claude mcp get mcp-portal"
        try:   # Claude Code renews its own login; this code never does
            subprocess.run(shlex.split(warm), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           timeout=min(90, max(5, self.deadline - time.time())), check=False)
        except (OSError, subprocess.SubprocessError):
            pass
        left = self.load()
        if left is not None and left < SKEW:
            raise AuthError("the portal login token has expired and Claude Code did not renew it")

    def scrub(self, s):
        s = str(s)
        return s.replace(self.token, "<token>") if self.token else s

    def post(self, payload, notification=False):
        remaining = self.deadline - time.time()
        if remaining <= 2:
            raise FetchError("timed out")
        headers = {"Authorization": "Bearer " + self.token, "Content-Type": "application/json",
                   "Accept": "application/json, text/event-stream", "MCP-Protocol-Version": PROTOCOL,
                   "User-Agent": USER_AGENT}
        if self.sid:
            headers["Mcp-Session-Id"] = self.sid
        req = urllib.request.Request(self.url, data=json.dumps(payload).encode(), headers=headers, method="POST")
        last = None
        for attempt in (0, 1):
            try:
                with urllib.request.urlopen(req, timeout=min(60, max(3, self.deadline - time.time()))) as r:
                    self.sid = r.headers.get("Mcp-Session-Id") or self.sid
                    body = r.read().decode("utf-8", "replace")
                    ctype = r.headers.get("Content-Type", "")
                break
            except urllib.error.HTTPError as e:
                text = self.scrub(e.read().decode("utf-8", "replace"))
                if e.code in (401, 403) and "1010" not in text:
                    raise AuthError(f"the portal refused the login (HTTP {e.code})")
                if e.code in (401, 403):
                    raise FetchError(f"the portal's edge blocked the request (HTTP {e.code})")
                last = FetchError(f"the portal answered HTTP {e.code}")
            except (urllib.error.URLError, TimeoutError, OSError) as e:
                last = FetchError(f"the portal was not reached ({type(e).__name__})")
            if attempt == 0 and time.time() + 4 < self.deadline:
                time.sleep(3)
            else:
                raise last
        if notification:
            return None
        if "text/event-stream" in ctype:
            msgs = []
            for line in body.splitlines():
                if line.startswith("data:") and line[5:].strip():
                    try:
                        msgs.append(json.loads(line[5:].strip()))
                    except ValueError:
                        pass
            msgs = [m for m in msgs if isinstance(m, dict) and m.get("id") == payload.get("id")] or msgs
            return msgs[-1] if msgs else None
        try:
            return json.loads(body)
        except ValueError:
            raise FetchError("the portal's answer was not JSON")

    def open(self):
        r = self.post({"jsonrpc": "2.0", "id": self._id(), "method": "initialize", "params": {
            "protocolVersion": PROTOCOL, "capabilities": {}, "clientInfo": {"name": CLIENT_NAME, "version": "1"}}})
        if not isinstance(r, dict) or "result" not in r:
            raise FetchError("the portal did not accept the session")
        self.post({"jsonrpc": "2.0", "method": "notifications/initialized"}, notification=True)

    def _id(self):
        self.n += 1
        return self.n

    def read(self, tool, args, body_raw=0):
        """One Gmail read through portal_codemode_execute; the text the Workspace server answered.

        self.cut says whether the portal cut this answer at its size limit (the text is then what came before the cut)."""
        code = read_code(tool, args, body_raw)
        self.cut = False
        r = self.post({"jsonrpc": "2.0", "id": self._id(), "method": "tools/call",
                       "params": {"name": "portal_codemode_execute", "arguments": {"code": code}}})
        if not isinstance(r, dict):
            raise FetchError("no answer to a read")
        if "error" in r:
            msg = self.scrub((r["error"] or {}).get("message") if isinstance(r["error"], dict) else r["error"])[:200]
            raise (AuthError if AUTH_RE.search(msg) else FetchError)(f"the portal returned an error: {msg}")
        res = r.get("result") or {}
        text = "\n".join(c.get("text", "") for c in res.get("content", []) if isinstance(c, dict))
        try:
            obj = json.loads(text)
            if isinstance(obj, dict) and isinstance(obj.get("result"), str):
                text = obj["result"]
            elif isinstance(obj, dict) and "error" in obj:
                text = str(obj["error"])
                res = {"isError": True}
        except ValueError:
            cut = decode_cut(text)
            if cut is not None:
                text, self.cut = cut, True
        if res.get("isError"):
            msg = self.scrub(text)[:200].replace("\n", " ")
            raise (AuthError if AUTH_RE.search(msg) else FetchError)(f"a read failed: {msg}")
        self.reads += 1
        return text

    def read_messages(self, ids):
        """{message_id: {"headers", "body"}} for the ids, in small trimmed batches; a batch the portal cut is split in halves."""
        out = {}
        todo = [ids[i:i + BATCH_SIZE] for i in range(0, len(ids), BATCH_SIZE)]
        while todo:
            chunk = todo.pop(0)
            text = self.read(BATCH_TOOL, {"message_ids": chunk}, BODY_RAW)
            if self.cut and len(chunk) > 1:
                half = len(chunk) // 2
                todo[:0] = [chunk[:half], chunk[half:]]
                continue
            out.update(parse_messages(text))   # one message cut is a short body at worst: its headers come first
        return out


def decode_cut(text):
    """The string a portal answer {"result": "..."} held before the portal cut it at its size limit, or None when the text
    is not such a cut answer. The cut leaves invalid JSON (the string never closes) and ends with the TRUNCATED notice."""
    m = re.match(r'\s*\{\s*"result"\s*:\s*"', text)
    if not m or TRUNC_MARK not in text:
        return None
    piece = text[m.end():text.rindex(TRUNC_MARK)].rstrip("\n")
    piece = re.sub(r"(?<!\\)((?:\\\\)*)\\(u[0-9a-fA-F]{0,3})?$", r"\1", piece)   # a half escape at the cut
    try:
        return json.loads('"' + piece + '"', strict=False)
    except ValueError:
        return piece.replace("\\n", "\n").replace('\\"', '"').replace("\\\\", "\\")


AUTH_RE = re.compile(r"re-?authori[sz]|invalid_grant|unauthenticated|unauthori[sz]ed|\b40[13]\b|token (has )?expired|needs? (to )?(re-?)?auth|oauth", re.I)


# --- parsing what the Workspace server answers --------------------------------------------------------------------

def parse_search(text):
    """([(message_id, thread_id)], more) from search_gmail_messages' text. FetchError when it is neither a result nor 'none'."""
    if re.search(r"No messages found", text, re.I):
        return [], False
    if not re.search(r"Found\s+\d+\s+messages?", text, re.I):
        if AUTH_RE.search(text):
            raise AuthError("the Gmail read was refused: " + re.sub(r"\s+", " ", text)[:160])
        raise FetchError("the search answered something that is not a result list")
    out, seen = [], set()
    for m in re.finditer(r"Message ID:\s*(\w+)\s*\n(?:.*\n)*?\s*Thread ID:\s*(\w+)", text):
        if m.group(1) not in seen:
            seen.add(m.group(1))
            out.append((m.group(1), m.group(2)))
    more = bool(re.search(r"next page", text, re.I))
    return out, more


def parse_messages(text):
    """{message_id: {"headers": {lower-name: value}, "body": str}} from get_gmail_messages_content_batch's text."""
    msgs = {}
    parts = re.split(r"(?:^|\n\n|\n---\n\n)(?=Message ID: \w+\n)", text)
    for part in parts:
        m = re.match(r"Message ID: (\w+)\n", part)
        if not m:
            continue
        head, _, body = part[m.end():].partition("--- BODY ---")
        headers = {}
        for line in head.splitlines():
            h = re.match(r"([A-Za-z][A-Za-z0-9-]*):\s?(.*)$", line)
            if h:
                headers.setdefault(h.group(1).lower(), h.group(2).strip())
        body = body.strip("\n")
        body = re.sub(r"\n---\s*$", "", body)
        msgs[m.group(1)] = {"headers": headers, "body": body}
    return msgs


# --- trimming -----------------------------------------------------------------------------------------------------

class _Text(HTMLParser):
    BLOCK = {"p", "div", "br", "tr", "li", "h1", "h2", "h3", "h4", "table", "ul", "ol", "blockquote", "hr"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.out, self.skip = [], 0

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style", "head"):
            self.skip += 1
        elif tag in self.BLOCK:
            self.out.append("\n")

    def handle_endtag(self, tag):
        if tag in ("script", "style", "head"):
            self.skip = max(0, self.skip - 1)
        elif tag in self.BLOCK:
            self.out.append("\n")

    def handle_data(self, d):
        if not self.skip:
            self.out.append(d)


def html_to_text(s):
    p = _Text()
    try:
        p.feed(s)
        p.close()
    except Exception:
        return re.sub(r"<[^>]+>", " ", s)
    return "".join(p.out)


ON_WROTE = re.compile(r"^On .{5,200}wrote:\s*$", re.I)
ON_WRAPPED = re.compile(r"^On .{5,200}$", re.I)            # "On Mon, 5 Oct ..." whose "wrote:" is on the next line
WROTE_END = re.compile(r"wrote:\s*$", re.I)
OUTLOOK_HEAD = re.compile(r"^From\s*:")      # an Outlook-style quoted header block
OUTLOOK_FOLLOW = re.compile(r"\b(Sent|Date|To|Subject)\s*:")
STOP_LINE = [
    re.compile(r"^-{2,}\s*(Original Message|Forwarded message)\s*-{2,}", re.I),
    re.compile(r"^_{8,}\s*$"),
    re.compile(r"^-- ?$"),                                        # the signature delimiter
    re.compile(r"^(Sent from my |Get Outlook for |Sent with )", re.I),
]
FOOTER = re.compile(r"unsubscribe|view (this )?(email )?in (your )?browser|manage (your )?(email )?preferences|"
                    r"you are receiving this|update your preferences", re.I)
URL = re.compile(r"<?https?://[^\s<>)\]]+>?")


def cut_quotes(lines):
    """The lines before the first quoted reply, signature or forwarded header; '>' lines dropped."""
    out = []
    for i, line in enumerate(lines):
        s = line.strip()
        if s.startswith(">"):
            continue
        nxt = lines[i + 1].strip() if i + 1 < len(lines) else ""
        if ON_WROTE.match(s) or (ON_WRAPPED.match(s) and len(nxt) < 120 and WROTE_END.search(nxt)):
            break
        if OUTLOOK_HEAD.match(s) and OUTLOOK_FOLLOW.search(" ".join(x.strip() for x in lines[i + 1:i + 4])):
            break
        if any(p.match(s) for p in STOP_LINE):
            break
        out.append(line)
    return out


def clean_body(raw, limit, automated=False, keep_links=False):
    s = raw.replace("\r\n", "\n").replace("\r", "\n")
    s = re.sub(r"[​-‏⁠﻿­]", "", s)
    if re.search(r"<\s*(html|body|div|table|p|br|span)\b", s, re.I):
        s = html_to_text(s)
    lines = [ln.rstrip() for ln in s.split("\n")]
    lines = cut_quotes(lines)
    text = "\n".join(lines)
    if automated:
        m = FOOTER.search(text)
        if m and m.start() > 150:
            text = text[: m.start()]
    if not keep_links:
        text = URL.sub("[link]", text)
    text = re.sub(r"(\[link\][\s,.;:|·\-]*){2,}", "[link] ", text)
    text = re.sub(r"^[\s\-_=*•·|]{3,}$", "", text, flags=re.M)
    text = re.sub(r"[ \t ]+", " ", text)
    text = re.sub(r"\n[ \t]*", "\n", text)
    text = re.sub(r"\n{2,}", "\n", text).strip()
    text = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]", "", text)
    return clip(text.replace("\n", " ⏎ "), limit)


def clip(s, n):
    if len(s) <= n:
        return s
    cut = s[: max(0, n - 1)]
    sp = cut.rfind(" ")
    if sp > n * 0.6:
        cut = cut[:sp]
    return cut.rstrip() + "…"


def one_line(s, n=200):
    s = re.sub(r"[\x00-\x1f\x7f-\x9f]", " ", s or "")
    return clip(re.sub(r"\s+", " ", s).strip(), n)


WEEKDAYS = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")


def ordinal(n):
    """1st 2nd 3rd 4th ... 11th 12th 13th ... 21st 22nd 23rd ... 31st"""
    return f"{n}{'th' if 10 <= n % 100 <= 20 else {1: 'st', 2: 'nd', 3: 'rd'}.get(n % 10, 'th')}"


def fmt_local(d):
    """The owner's date form, in the local zone (TZ, which lib.sh sets from BRIEFING_TZ): `Mon Oct 26th 14:03` (weekday, month,
    day with an ordinal suffix, 24-hour time). Written out of tables, not strftime, so the box's locale cannot change it."""
    d = d.astimezone()
    return f"{WEEKDAYS[d.weekday()]} {MONTHS[d.month - 1]} {ordinal(d.day)} {d:%H:%M}"


def local_time(date_header):
    try:
        d = parsedate_to_datetime(date_header)
        if d.tzinfo is None:
            d = d.replace(tzinfo=timezone.utc)
        return d, fmt_local(d)
    except (TypeError, ValueError, IndexError):
        return datetime(1970, 1, 1, tzinfo=timezone.utc), "unknown date"


def unwrap_google(url):
    q = urlparse(url)
    if q.netloc.endswith("google.com") and q.path == "/url":
        real = parse_qs(q.query).get("url") or parse_qs(q.query).get("q")
        if real:
            return real[0]
    return url


def alert_items(body, limit_items):
    """[(title, snippet, url)] from a Google Alerts text mail, destination URLs unwrapped from google.com/url.

    The mail is, per article: the title (wrapped lines end in two spaces), the snippet (its first line starts with
    "..."), then `<https://www.google.com/url?...&url=DESTINATION&...>`; a line of "- - - -" starts the footer."""
    items, buf = [], []
    for raw in body.replace("\r\n", "\n").split("\n"):
        s = raw.strip()
        if s.startswith("- - - -"):
            break
        m = re.fullmatch(r"<?(https?://[^\s<>]+)>?", s)
        if m and "google.com/url" in m.group(1):
            lines = [b for b in buf if b.strip()]
            split = next((i for i, b in enumerate(lines) if i > 0 and b.lstrip().startswith(("...", "\u2026"))), None)
            if split is not None:
                head, rest = lines[:split], lines[split:]
            else:
                head = []
                for b in lines:
                    head.append(b)
                    if not b.endswith("  "):
                        break
                rest = lines[len(head):]
            title = re.sub(r"\s+", " ", " ".join(head)).strip()
            snippet = re.sub(r"\s+", " ", " ".join(rest)).strip()
            if title:
                items.append((one_line(title, 200), one_line(snippet, 140), unwrap_google(m.group(1))))
            buf = []
            if len(items) >= limit_items:
                break
        elif s.startswith("==="):
            buf = []
        else:
            buf.append(raw)
    return items


AUTOMATED_SENDER = re.compile(r"no-?reply|do-?not-?reply|notification|mailer|bounce|alerts?@|news(letter)?@|digest|updates?@|"
                              r"info@|hello@|team@|support@|marketing", re.I)


def classify(h):
    frm = h.get("from", "")
    if "googlealerts-noreply@" in frm.lower():   # Google Alerts' own sender
        return "alert"
    if h.get("list-unsubscribe") or h.get("list-id") or h.get("precedence", "").lower() in ("bulk", "list", "junk") \
            or AUTOMATED_SENDER.search(frm):
        return "automated"
    return "human"


def sender_name(frm):
    m = re.match(r'\s*"?([^"<]+?)"?\s*<', frm or "")
    return one_line(m.group(1) if m else (frm or "?"), 40)


def build_items(threads, tiers):
    """The trimmed items for one budget tier; threads is [(thread_id, [unread messages, oldest first])]."""
    human_cap, auto_cap, alert_n = tiers
    items, seen_urls = [], set()
    for tid, msgs in threads:
        h = msgs[-1]["headers"]   # the newest unread message speaks for the thread
        kind = classify(h)
        item = {"thread": tid, "kind": kind, "unread_in_thread": len(msgs), "from": one_line(h.get("from", "?"), 120),
                "date": local_time(h.get("date", ""))[1], "subject": one_line(h.get("subject", "(no subject)"), 160)}
        if kind == "alert":
            alerts = []
            for m in msgs:
                alerts += alert_items(m["body"], alert_n + 6)
            alerts = [a for a in alerts if a[2] not in seen_urls][:alert_n]
            seen_urls.update(a[2] for a in alerts)
            item["alerts"] = alerts
        else:
            cap = human_cap if kind == "human" else auto_cap
            each = cap if len(msgs) == 1 else max(cap // len(msgs), 120)
            parts = [clean_body(m["body"], each, automated=(kind == "automated")) for m in msgs]
            item["body"] = parts[0] if len(msgs) == 1 else " ⏎ ↳ ".join(
                f"({sender_name(m['headers'].get('from'))}) {p}" for m, p in zip(msgs, parts))
        items.append(item)
    return items


def render_item(i, it):
    return frame_safe(_render_item(i, it))   # mail text can never close or reopen the data block


def _render_item(i, it):
    lines = [f"[{i}] thread={it['thread']} kind={it['kind']} unread_in_thread={it['unread_in_thread']}",
             f"From: {it['from']}", f"Date: {it['date']}", f"Subject: {it['subject']}"]
    if it["kind"] == "alert":
        if it["alerts"]:
            lines.append("Articles (title | snippet | destination URL):")
            lines += [f"- {t} | {sn} | {u}" if sn else f"- {t} | | {u}" for t, sn, u in it["alerts"]]
        else:
            lines.append("Articles: none left after removing repeats")
    else:
        lines.append(f"Body: {it['body'] or '(empty)'}")
    return "\n".join(lines)


def frame_safe(s):
    return re.sub(r"</?unread-mail-data", "(unread-mail-data", s, flags=re.I)


TIERS = [(900, 400, 6), (500, 240, 4), (320, 160, 3), (200, 100, 2), (120, 60, 1)]
ORDER = {"human": 0, "automated": 1, "alert": 2}


def compose(unread, more, threads, max_chars):
    """(text, shown, omitted): the framed block, shrunk tier by tier until it fits max_chars."""
    ordered = sorted(threads, key=lambda t: (ORDER[classify(t[1][-1]["headers"])], -local_time(t[1][-1]["headers"].get("date", ""))[0].timestamp()))
    for tiers in TIERS:
        items = build_items(ordered, tiers)
        if sum(len(render_item(i + 1, it)) + 2 for i, it in enumerate(items)) <= max_chars:
            break
    shown = list(items)
    while shown and sum(len(render_item(i + 1, it)) + 2 for i, it in enumerate(shown)) > max_chars:
        shown.pop()
    omitted = len(items) - len(shown)
    head = (f'{FRAME_OPEN} unread="{unread}{"+" if more else ""}" threads="{len(items)}" shown="{len(shown)}" omitted="{omitted}">')
    body = "\n\n".join(render_item(i + 1, it) for i, it in enumerate(shown))
    return (f"{head}\n{body}\n{FRAME_CLOSE}" if shown else f"{head}\n(no unread mail)\n{FRAME_CLOSE}"), len(shown), omitted


# --- the run ------------------------------------------------------------------------------------------------------

EMPTY_FIRST = 5          # any empty thread among the first this many fails the run
EMPTY_SHARE = 0.20       # ... and so do more than this share of all of them


def is_empty(msgs):
    """A thread whose newest unread message came back with neither a subject nor a sender."""
    h = msgs[-1]["headers"] if msgs else {}
    return not (h.get("subject") or "").strip() and not (h.get("from") or "").strip()


def check_readable(threads):
    """Count the empty threads; FetchError when the mail did not really come back (never a digest made of nothing)."""
    empty = [is_empty(msgs) for _, msgs in threads]
    n = sum(empty)
    if n and (any(empty[:EMPTY_FIRST]) or n > EMPTY_SHARE * len(threads)):
        raise FetchError(f"Gmail came back with empty threads ({n} of {len(threads)} have no subject and no sender)")
    return n


def fetch(query, page_size, max_chars, deadline):
    portal = Portal(deadline)
    portal.ensure_fresh()
    portal.open()
    found, more = parse_search(portal.read(PREFIX + "search_gmail_messages", {"query": query, "page_size": page_size}))
    more = more or portal.cut or len(found) >= page_size   # the portal masks the next-page token: a full page may be only the first
    by_thread, order = {}, []
    ids = [m for m, _ in found]
    msgs = portal.read_messages(ids)
    for mid, tid in found:
        m = msgs.get(mid) or {"headers": {}, "body": ""}
        if tid not in by_thread:
            by_thread[tid] = []
            order.append(tid)
        by_thread[tid].append(m)
    threads = [(tid, sorted(by_thread[tid], key=lambda m: local_time(m["headers"].get("date", ""))[0].timestamp())) for tid in order]
    empty = check_readable(threads)
    text, shown, omitted = compose(len(found), more, threads, max_chars)
    meta = {"unread": len(found), "more": more, "threads": len(threads), "shown": shown, "omitted": omitted,
            "reads": portal.reads, "empty": empty, "chars": len(text)}
    return text, meta


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--query", default="is:unread")
    ap.add_argument("--page-size", type=int, default=100)
    ap.add_argument("--meta-file", default="")
    a = ap.parse_args(argv)
    deadline = time.time() + float(os.environ.get("BRIEFING_LEAN_TIMEOUT") or 240)
    max_chars = int(os.environ.get("BRIEFING_LEAN_MAX_CHARS") or 30000)
    if not PREFIX:
        print("gmail_fetch: BRIEFING_GMAIL_CONNECTOR is not set (one word, the connector's): no Gmail read is allowed", file=sys.stderr)
        return EXIT_FAIL
    try:
        text, meta = fetch(a.query, a.page_size, max_chars, deadline)
    except AuthError as e:
        print(f"gmail_fetch: {e}", file=sys.stderr)
        return EXIT_AUTH
    except FetchError as e:
        print(f"gmail_fetch: {e}", file=sys.stderr)
        return EXIT_FAIL
    except Exception as e:   # a bug here must still end as a failure notice, never as a digest
        print(f"gmail_fetch: {type(e).__name__}: {str(e)[:160]}", file=sys.stderr)
        return EXIT_FAIL
    if a.meta_file:
        with open(a.meta_file, "w", encoding="utf-8") as f:
            json.dump(meta, f)
    sys.stdout.write(text + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
