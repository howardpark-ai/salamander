#!/usr/bin/env python3
"""tests/briefing/awslimit.sh runs this: contrib/briefing/aws_limit.py on made-up emails (organization "Example Org"). Offline: the mailbox is
a function that hands back messages, the state file is in a temp folder that is removed at the end. Prints `ok ...` / `FAIL ...` lines; exit 1 on a failure."""
import importlib.util
import json
import os
import shutil
import sys
import tempfile
from datetime import datetime, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
spec = importlib.util.spec_from_file_location("aws_limit", os.path.join(ROOT, "contrib", "briefing", "aws_limit.py"))
A = importlib.util.module_from_spec(spec)
spec.loader.exec_module(A)

fails = 0


def check(name, cond, extra=""):
    global fails
    print(("  ok   " if cond else "  FAIL ") + name + ("" if cond else "  " + str(extra)))
    fails += 0 if cond else 1


def body(limit="$1000.00", tier="Tier 3", until="December 1, 2026", org="Example Org", dot=True):
    """An email's text the way the portal hands an HTML mail over: block breaks missing between the sentences."""
    return ("Your organization has reached its monthly usage thresholdWe wanted to alert you that your account balance has crossed the %s "
            "monthly API usage threshold for your organization “%s%s” The threshold was set based on your API tier (%s).\n"
            "Further API usage is now paused for your organization until midnight UTC on %s.Visit our documentation for more information "
            "about API usage limits.Example Sender, PBC1 Example Street, Example City" % (limit, org, "." if dot else "", tier, until))


FROM = "Example Sender <alerts@anthropic.com>"   # how the portal hands the From header over: a name and an address


def hdr(date, frm=FROM, subject=None):
    return {"subject": subject or A.SUBJECT, "from": frm, "date": date}


def msg(date, **kw):
    frm, subject = kw.pop("frm", FROM), kw.pop("subject", A.SUBJECT)
    return {"headers": hdr(date, frm, subject), "body": body(**kw)}


T = tempfile.mkdtemp(prefix="awslimit-check-")
try:
    # --- the parser -------------------------------------------------------------------------------------------------
    got = A.parse_body(body())
    check("$1000 / Tier 3 / December 1: limit, tier and the pause instant (midnight UTC)", got == {
        "org": "Example Org", "limit": 1000, "tier": 3, "paused_until": "2026-12-01T00:00:00Z"}, got)
    got = A.parse_body(body(limit="$500.00", tier="Tier 2", until="November 1, 2026"))
    check("$500 / Tier 2 / November 1", got and (got["limit"], got["tier"], got["paused_until"]) == (500, 2, "2026-11-01T00:00:00Z"), got)
    got = A.parse_body(body(limit="$2,500.50", tier="Tier 4", until="February 9, 2027"))
    check("a thousands comma, cents and a single-digit day parse", got and (got["limit"], got["tier"], got["paused_until"]) == (2500.5, 4, "2027-02-09T00:00:00Z"), got)
    check("the organization is read without its closing dot", A.parse_body(body(dot=False))["org"] == "Example Org")
    check("straight quotes and extra whitespace parse too", A.parse_body(body().replace("“", '"').replace("”", '"').replace(" ", "  \n")) is not None)
    for name, text in (("garbage text", "Lorem ipsum, nothing about limits."), ("an empty text", ""), ("None", None),
                       ("no tier", body().replace("(Tier 3)", "")), ("no limit", body().replace("crossed the $1000.00", "crossed the")),
                       ("no pause date", body(until="soon")), ("an impossible date", body(until="February 31, 2026")),
                       ("a zero limit", body(limit="$0.00")), ("no organization", body().replace("organization “Example Org.”", "organization"))):
        check("%s: None" % name, A.parse_body(text) is None)

    # --- one message --------------------------------------------------------------------------------------------------
    got = A.parse_message(msg("Mon, 09 Nov 2026 12:33:09 +0000 (UTC)")["headers"], body(), "Example Org")
    check("the email date is the Date header in UTC", got and got["email_date"] == "2026-11-09T12:33:09Z", got)
    got = A.parse_message(hdr("Mon, 09 Nov 2026 21:33:09 +0900"), body(), "example org")
    check("a zone offset is converted and the organization matches without regard to case", got and got["email_date"] == "2026-11-09T12:33:09Z", got)
    check("another organization is ignored", A.parse_message(msg("Mon, 09 Nov 2026 12:33:09 +0000")["headers"], body(org="Other Org"), "Example Org") is None)
    check("no organization configured: nothing matches", A.parse_message(msg("Mon, 09 Nov 2026 12:33:09 +0000")["headers"], body(), "") is None)
    check("another subject is ignored", A.parse_message(hdr("Mon, 09 Nov 2026 12:33:09 +0000", subject="Your receipt"), body(), "Example Org") is None)
    check("no readable Date header: None", A.parse_message(hdr("yesterday-ish"), body(), "Example Org") is None)

    # --- the sender -------------------------------------------------------------------------------------------------------
    D = "Mon, 09 Nov 2026 12:33:09 +0000"
    for frm, want in (("Example Sender <alerts@anthropic.com>", True), ("alerts@anthropic.com", True), ("<alerts@anthropic.com>", True),
                      ('"Example Sender" <alerts@Anthropic.COM>', True), ("alerts@mail.anthropic.com", True),
                      ("alerts@example.com", False), ("alerts@anthropic.com.example.net", False), ("alerts@notanthropic.com", False),
                      ("alerts@example.com.anthropic.com.example.net", False), ("anthropic.com <alerts@example.com>", False),
                      ("Example Sender <alerts@example.com>", False), ("alerts@anthropic.com, other@example.com", False),
                      ("", False), (None, False), ("anthropic.com", False), ("alerts@@anthropic.com", False)):
        got = A.parse_message(hdr(D, frm), body(), "Example Org")
        check("sender %r: %s" % (frm, "accepted" if want else "ignored"), bool(got) == want, got)
    check("no From header at all: ignored", A.parse_message({"subject": A.SUBJECT, "date": D}, body(), "Example Org") is None)
    check("the newest of the organization from another sender is ignored: the Anthropic one stands",
          (A.newest({"m1": msg(D), "m2": msg("Fri, 13 Nov 2026 08:00:00 +0000", frm="alerts@example.com", limit="$9000.00")}, "Example Org") or {}).get("limit") == 1000)

    # --- the newest of several ----------------------------------------------------------------------------------------
    msgs = {"m1": msg("Tue, 27 Oct 2026 06:21:15 +0000", limit="$500.00", tier="Tier 2", until="November 1, 2026"),
            "m2": msg("Mon, 02 Nov 2026 01:41:35 +0000", limit="$500.00", tier="Tier 2"),
            "m3": msg("Mon, 09 Nov 2026 12:33:09 +0000"),
            "m4": msg("Fri, 13 Nov 2026 08:00:00 +0000", org="Other Org", limit="$9000.00", tier="Tier 4"),
            "m5": {"headers": hdr("Sat, 14 Nov 2026 08:00:00 +0000"), "body": "garbage"}}
    got = A.newest({k: v for k, v in msgs.items() if k != "m5"}, "Example Org")
    check("the newest email of the organization wins (a newer one of another organization does not)",
          got and (got["limit"], got["tier"], got["email_date"]) == (1000, 3, "2026-11-09T12:33:09Z"), got)
    # a newest alert of the organization that lacks a fact: None, never an older alert's figures
    one = {"m1": msg("Tue, 27 Oct 2026 06:21:15 +0000", limit="$500.00", tier="Tier 2", until="November 1, 2026"),
           "m2": msg("Mon, 09 Nov 2026 12:33:09 +0000", tier="no tier named")}
    check("the newest alert of the organization lacks its tier and an older one parses: None (the older one does not take its place)", A.newest(one, "Example Org") is None, A.newest(one, "Example Org"))
    cut = msg("Mon, 09 Nov 2026 12:33:09 +0000"); cut["body"] = cut["body"].split("The threshold was set")[0]
    check("a newest alert cut off before its tier: None", A.newest({"m1": msgs["m1"], "m2": cut}, "Example Org") is None)
    check("the newest alert of the organization lacks the pause date: None", A.newest({"m1": msgs["m1"], "m2": msg("Mon, 09 Nov 2026 12:33:09 +0000", until="soon")}, "Example Org") is None)
    check("the newest message names no organization (it cannot be the organization's): the older parseable one stands",
          (A.newest({"m1": msgs["m1"], "m2": {"headers": hdr("Mon, 09 Nov 2026 12:33:09 +0000"), "body": "garbage"}}, "Example Org") or {}).get("email_date") == "2026-10-27T06:21:15Z")
    check("a newer unparseable alert of ANOTHER organization does not block the organization's own",
          (A.newest({"m1": msgs["m1"], "m2": msg("Mon, 09 Nov 2026 12:33:09 +0000", org="Other Org", tier="no tier named")}, "Example Org") or {}).get("tier") == 2)
    check("a newest alert with no readable date cannot be ranked: ignored", (A.newest({"m1": msgs["m1"], "m2": {"headers": hdr("later"), "body": body()}}, "Example Org") or {}).get("email_date") == "2026-10-27T06:21:15Z")
    check("a different month: the pause date follows its email", A.newest({"m": msg("Thu, 03 Dec 2026 10:00:00 +0000", until="January 1, 2027")}, "Example Org")["paused_until"] == "2027-01-01T00:00:00Z")
    check("no message: None", A.newest({}, "Example Org") is None and A.newest(None, "Example Org") is None)
    check("only another organization's mail: None", A.newest({"m": msg("Mon, 09 Nov 2026 12:33:09 +0000", org="Other Org")}, "Example Org") is None)

    # --- the state file -------------------------------------------------------------------------------------------------
    path = os.path.join(T, "state", "aws-api-limit.json")
    now = datetime(2026, 11, 20, 10, 0, 0, tzinfo=timezone.utc)
    rc, line = A.run("Example Org", path, lambda: msgs, now)
    doc = json.load(open(path))
    check("run writes limit, tier, paused_until, email_date, fetched_at (and the organization as the email names it)", rc == 0 and line == "" and doc == {
        "v": 1, "limit": 1000, "tier": 3, "paused_until": "2026-12-01T00:00:00Z", "email_date": "2026-11-09T12:33:09Z", "org": "Example Org",
        "fetched_at": "2026-11-20T10:00:00Z"}, doc)
    check("the state file is owner-only and no temp file is left beside it", oct(os.stat(path).st_mode & 0o777) == "0o600" and os.listdir(os.path.dirname(path)) == ["aws-api-limit.json"], os.listdir(os.path.dirname(path)))
    before = open(path).read()
    rc, line = A.run("Example Org", path, lambda: {"x": msg("Mon, 09 Nov 2026 12:33:09 +0000", org="Other Org")}, now)
    check("no email of the organization: exit 0, a line that says so, the file as it was", rc == 0 and "left as it was" in line and open(path).read() == before, line)
    rc, line = A.run("Example Org", path, lambda: {"x": msg("Fri, 13 Nov 2026 08:00:00 +0000", frm="alerts@example.com", limit="$9000.00")}, now)
    check("only a lookalike sender's mail: exit 0, the file as it was", rc == 0 and "left as it was" in line and open(path).read() == before, line)
    rc, line = A.run("Example Org", path, lambda: {"a": msg("Tue, 27 Oct 2026 06:21:15 +0000", limit="$500.00", tier="Tier 2", until="November 1, 2026"),
                                                  "b": msg("Fri, 13 Nov 2026 08:00:00 +0000", tier="no tier named")}, now)
    check("the newest alert lacks its tier, an older one parses: exit 0, a line that says so, the file untouched (the older figures do not overwrite it)",
          rc == 0 and "left as it was" in line and open(path).read() == before, line)
    rc, line = A.run("", path, lambda: (_ for _ in ()).throw(AssertionError("the mailbox must not be read")), now)
    check("no organization set: the mailbox is not read and nothing is written", rc == 0 and "SALA_AWS_LIMIT_ORG" in line and open(path).read() == before, line)

    def boom():
        raise RuntimeError("the portal was not reached")
    try:
        A.run("Example Org", path, boom, now)
        check("a failed read raises (main turns it into exit 4)", False)
    except RuntimeError:
        check("a failed read raises (main turns it into exit 4) and the file is as it was", open(path).read() == before)

    # --- the paging default -------------------------------------------------------------------------------------------------
    seen = {}
    A.fetch_messages = lambda page_size, deadline, G=None: seen.setdefault("n", page_size) and {}
    os.environ["SALA_AWS_LIMIT_ORG"] = "Example Org"
    A._gmail_fetch = lambda: None
    A.main(["--state-file", os.path.join(T, "paging.json")])
    check("the default page size is 50", seen.get("n") == 50, seen)
    os.environ.pop("SALA_AWS_LIMIT_ORG", None)

    # --- the command line: no organization, no read ----------------------------------------------------------------------
    env = dict(os.environ)
    os.environ.pop("SALA_AWS_LIMIT_ORG", None)
    rc = A.main(["--state-file", os.path.join(T, "none.json")])
    check("main without an organization exits 0 and writes no file", rc == 0 and not os.path.exists(os.path.join(T, "none.json")))
    os.environ.clear(); os.environ.update(env)
finally:
    shutil.rmtree(T, ignore_errors=True)
sys.exit(1 if fails else 0)
