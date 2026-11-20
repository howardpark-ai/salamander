#!/usr/bin/env python3
"""aws_limit.py: the API spend limit, tier and pause that Anthropic's threshold emails announce, kept in a state file for sala's Overview.

When an organization's monthly API spend crosses its threshold, Anthropic emails "Monthly Claude API Spend Exceeding Thresholds":
the dollar threshold, the API tier it was set from, and the instant API use is paused until ("midnight UTC on December 1, 2026").
There is no API for these three facts, so this job reads the newest such email of the owner's mailbox and writes them to a small
JSON file; the web app (web/src/sala_web/spend.py) reads the file and the aws-platform card shows one line from it.

  aws_limit.py [--state-file F] [--org NAME] [--page-size 50]

The mailbox is read exactly as gmail_fetch.py reads it (its Portal class: the portal's Gmail reads, signed with the login Claude
Code already holds; read only, never a refresh, never a write). Nothing here builds a second Gmail client.

Which emails count: the subject below, a sender at Anthropic's own mail domain (anthropic.com or a subdomain of it, by the From header's
address), AND the organization the email names, which must be the one SALA_AWS_LIMIT_ORG names (the environment, else the sala config
line; config.example). Mail from another sender or about another organization is ignored. Of those, the newest by its Date header is the
one that counts: when it does not give all three facts the job writes nothing (an older email never takes its place). With no organization
set the job writes nothing and says so on stderr (exit 0): the card then shows no strip.

The state file (${XDG_STATE_HOME:-~/.local/state}/salamander/aws-api-limit.json: where the web app reads it; --state-file is for tests), written
atomically, one object:
  {"v": 1, "limit": 1000, "tier": 3, "paused_until": "2026-12-01T00:00:00Z", "email_date": "2026-11-09T12:33:09Z",
   "org": "<the organization as the email names it>", "fetched_at": "2026-11-20T10:00:00Z"}
Written only from a parsed email: a run that finds none, or whose newest email (of the sender and organization above) does not parse, leaves
the last file as it was (the web app marks a file whose email is more than 14 days old as stale, and shows none for another organization
than SALA_AWS_LIMIT_ORG names; it never invents a figure). fetched_at is when this run looked.

Exit 0: the mailbox was read (an email found and written, or none); 3: the login was refused or has expired; 4: any other failure.
One line on stderr says why; nothing is printed on stdout.
"""
import argparse
import importlib.util
import json
import os
import re
import sys
import tempfile
import time
from datetime import datetime, timezone
from email.utils import getaddresses, parsedate_to_datetime

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
SUBJECT = "Monthly Claude API Spend Exceeding Thresholds"
SENDER_DOMAIN = "anthropic.com"   # the mail domain the alert must come from (a subdomain of it counts)
STATE_VERSION = 1
EXIT_AUTH, EXIT_FAIL = 3, 4

_ORG = re.compile(r"\borganization\s+[“\"]([^”\"]{1,120})[”\"]")
_LIMIT = re.compile(r"crossed the \$\s*([0-9][0-9,]*(?:\.[0-9]+)?)\s+monthly API usage threshold", re.I)
_TIER = re.compile(r"\(\s*Tier\s+(\d+)\s*\)", re.I)
_UNTIL = re.compile(r"paused\b[^.]*?\buntil\s+midnight\s+UTC\s+on\s+([A-Za-z]+)\s+(\d{1,2}),\s*(\d{4})", re.I)


def _flat(text):
    """The text on one line, whitespace (non-breaking and zero-width spaces included) collapsed: the portal hands over an HTML mail as text whose
    block breaks may be missing ("thresholdWe wanted")."""
    return re.sub(r"\s+", " ", str(text or "").replace(" ", " ").replace("​", "")).strip()


def _org_key(name):
    return _flat(name).strip(" .,;:").casefold()


def parse_body(text):
    """{"org", "limit", "tier", "paused_until"} from one email's text, or None when any of the four facts is missing or odd."""
    t = _flat(text)
    org, lim, tier, until = _ORG.search(t), _LIMIT.search(t), _TIER.search(t), _UNTIL.search(t)
    if not (org and lim and tier and until):
        return None
    try:
        limit = float(lim.group(1).replace(",", ""))
        day = datetime.strptime("%s %s %s" % (until.group(1).title(), int(until.group(2)), until.group(3)), "%B %d %Y")
    except ValueError:
        return None
    if limit <= 0:
        return None
    return {"org": _flat(org.group(1)).rstrip(" .,;:"), "limit": int(limit) if limit == int(limit) else limit, "tier": int(tier.group(1)),
            "paused_until": day.replace(tzinfo=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}


def _iso(dt):
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def from_anthropic(frm):
    """True when the From header names exactly one address and it is at SENDER_DOMAIN or a subdomain of it. The portal hands the header as
    written: a bare address or `Name <address>`. The address is read the way a mail client reads it, so `anthropic.com <x@example.net>`
    and `x@anthropic.com.example.net` are not Anthropic's."""
    addrs = [a for _name, a in getaddresses([str(frm or "")]) if a]
    if len(addrs) != 1 or addrs[0].count("@") != 1:
        return False
    domain = addrs[0].rsplit("@", 1)[1].strip().rstrip(".").casefold()
    return domain == SENDER_DOMAIN or domain.endswith("." + SENDER_DOMAIN)


def _sent(headers):
    """The Date header as an ISO UTC string, or None when it is missing or unreadable."""
    try:
        sent = parsedate_to_datetime(headers.get("date") or "")
        if sent.tzinfo is None:
            sent = sent.replace(tzinfo=timezone.utc)
        return _iso(sent)
    except (TypeError, ValueError, IndexError, OverflowError):
        return None


def candidate(headers, body, org):
    """(email date, body text) when the message is an alert of the organization: the subject, a sender at Anthropic's own domain, the
    organization its text names (the one `org` is) and a readable Date header; else None. It does not need the other facts: a
    message of the organization that lacks one is still the organization's newest, see newest(). headers: {lower-case name: value}."""
    if SUBJECT.casefold() not in _flat(headers.get("subject")).casefold() or not from_anthropic(headers.get("from")):
        return None
    named = _ORG.search(_flat(body))
    if not org or not named or _org_key(named.group(1)) != _org_key(org):
        return None
    when = _sent(headers)
    return (when, body) if when else None


def parse_message(headers, body, org):
    """One message as the state's facts plus "email_date" (the Date header, UTC), or None: another subject, sender or organization,
    no readable date, or text that does not parse."""
    cand = candidate(headers, body, org)
    got = parse_body(cand[1]) if cand else None
    if got:
        got["email_date"] = cand[0]
    return got


def newest(messages, org):
    """The facts of the latest alert (by email date) among {id: {"headers", "body"}} of the sender and the organization, or None when there
    is none or that latest one does not give all three facts: an older alert never takes its place, so the state file stays as it was."""
    best = None
    for m in (messages or {}).values():
        cand = candidate(m.get("headers") or {}, m.get("body") or "", org)
        if cand and (best is None or cand[0] > best[0]):
            best = cand
    got = parse_body(best[1]) if best else None
    if got:
        got["email_date"] = best[0]
    return got


def write_state(path, fact, now):
    """Atomically: a temp file beside the target, fsynced, renamed over it. Owner-only, like the rest of the state folder."""
    doc = {"v": STATE_VERSION, "limit": fact["limit"], "tier": fact["tier"], "paused_until": fact["paused_until"],
           "email_date": fact["email_date"], "org": fact["org"], "fetched_at": _iso(now)}
    folder = os.path.dirname(path) or "."
    os.makedirs(folder, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=folder, prefix=".aws-api-limit-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(doc, f)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def default_state_path():
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(base, "salamander", "aws-api-limit.json")


def _gmail_fetch():
    """gmail_fetch.py, loaded by path (the job runs under python3 -I, which keeps this folder off sys.path). It reads
    BRIEFING_GMAIL_CONNECTOR when loaded, so this is called only after the environment is set."""
    spec = importlib.util.spec_from_file_location("briefing_gmail_fetch", os.path.join(HERE, "gmail_fetch.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def fetch_messages(page_size, deadline, G=None):
    """{id: {"headers", "body"}} of the mails with the subject, read through gmail_fetch's Portal. Raises G.AuthError / G.FetchError."""
    G = G or _gmail_fetch()
    if not G.PREFIX:
        raise G.FetchError("BRIEFING_GMAIL_CONNECTOR is not set (one word, the connector's): no Gmail read is allowed")
    portal = G.Portal(deadline)
    portal.ensure_fresh()
    portal.open()
    found, _more = G.parse_search(portal.read(G.PREFIX + "search_gmail_messages", {"query": 'subject:"%s"' % SUBJECT, "page_size": page_size}))
    return portal.read_messages([m for m, _ in found])


def run(org, state_path, messages_fn, now=None):
    """(exit code, one line for stderr or ""). messages_fn() returns the messages or raises an exception with a plain-words message."""
    if not org:
        return 0, "aws_limit: SALA_AWS_LIMIT_ORG is not set (config.example): nothing read, nothing written"
    now = now or datetime.now(timezone.utc)
    messages = messages_fn()
    fact = newest(messages, org)
    if fact is None:
        return 0, "aws_limit: no newest email of that organization with the three facts among %d found: the state file is left as it was" % len(messages)
    write_state(state_path, fact, now)
    return 0, ""


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--state-file", default="")
    ap.add_argument("--org", default="")
    ap.add_argument("--page-size", type=int, default=50)
    a = ap.parse_args(argv)
    org = a.org or os.environ.get("SALA_AWS_LIMIT_ORG", "")
    path = a.state_file or default_state_path()
    deadline = time.time() + float(os.environ.get("BRIEFING_LEAN_TIMEOUT") or 240)
    G = None
    try:
        if org:
            G = _gmail_fetch()
        rc, line = run(org, path, lambda: fetch_messages(a.page_size, deadline, G))
    except Exception as e:
        auth = G is not None and isinstance(e, G.AuthError)
        known = G is not None and isinstance(e, (G.AuthError, G.FetchError))
        print("aws_limit: %s" % (e if known else "%s: %s" % (type(e).__name__, str(e)[:160])), file=sys.stderr)
        return EXIT_AUTH if auth else EXIT_FAIL
    if line:
        print(line, file=sys.stderr)
    return rc


if __name__ == "__main__":
    sys.exit(main())
