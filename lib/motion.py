#!/usr/bin/env python3
"""lib/motion.py — `sala motion`: the short topics a session has promised to report back and has not reported yet (docs/subcommands.md).

sala-web's chat session view (web/README.md, *The chat session in sala's own view*) shows the chat session's under "On it". A session adds a line when it hands work
off with a promise to report back in the chat, and marks it done in the turn it reports the result. Nobody else writes the lines and no model filters them.

  add "<line>" [--item ID]
                        put a line on the list (one line of text, at most 120 characters; adding a line already open there changes nothing, except
                        that --item sets or replaces the board item the line belongs to). --item: the item's shown id (a name, a hash and a number); the chat
                        page links the line to that item the way it links a "my turn" line, when the board knows the id
  done "<line>" | N [--link URL]
                        mark one done, by its exact text or its number in `list`. For any session but the chat session the line is taken off (no page
                        shows its lines). The chat session's line is not removed: it is kept, marked done with the time and its result link, in the
                        owner's "my turn" list until he confirms it or replies to it on the chat page (either removes it). --link: an https address,
                        an in-app path (/...) or one of the page's own anchors (LINK_FORMS), anything else is refused; without it the page
                        links the first chat reply at or after the done time
  clear                 empty the list. The chat session's done lines the owner has not acknowledged stay; another session's go too
  list [--json]         the lines on the list, numbered; a done line is marked

  --for NAME            the session whose lines these are (default: the session this command runs in; outside a session it is required)

Storage: <state>/motion/<session>.json (state = SALA_STATE_DIR, else $XDG_STATE_HOME/salamander), folder mode 700, file mode 600, one small JSON
file per session: {"v": 1, "lines": [{"text": "...", "at": <epoch seconds, when the line was first added>, "done": <epoch seconds, when marked done,
or absent>, "link": "<result address, or absent>", "item": "<board item id, or absent>"}]}. The CLI is the writer, under an exclusive lock on <folder>/.lock; a file is written to a temporary
name, flushed and renamed, so a reader (sala-web, which only reads, except where it takes off an acknowledged line, under the same lock) never sees half of one.
At most 8 lines, each at most 120 characters: a ninth line and a longer one are refused with a sentence (nothing is cut or dropped silently).
The chat session is the one SALA_CHAT_SESSION names, read at each command the way sala-web reads it (chat_session below). Its done line stays until
the owner acknowledges it on the chat page, by its confirm or by a reply to it (sala-web takes the same lock and writes the same file): nothing here
removes it, `clear` included, and nothing expires it. A same-text `add` after a done line starts a new open line and leaves the done one.
No page shows another session's lines, so there `done` and `clear` take lines off, one marked done while that session was the chat session included.

Tests: SALA_MOTION_DIR (the folder), SALA_MOTION_NOW (the clock, epoch seconds), SALA_MOTION_SELF (the caller's own session name, which the shell
wrapper reads from sala's registry).
Exit: 0 done, 1 refused or failed, 2 usage.
"""
import fcntl
import json
import os
import re
import sys
import time

MAX_LINES = 8
MAX_CHARS = 120
LINK_MAX = 500
ITEM_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9#._-]{0,79}")   # an item's shown id as the board shows it (a name, a hash and a number, or s and a number)
NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
LINK_FORMS = "#s=SESSION, #lane=ID, #sessions, #schedules, #machines, #usage, #new, #search, #search?QUERY or #side=..."   # said by the refusal
# an https address; a path on this site ("//host", and "/\host" which a browser reads the same way, are another site); or one of the page's own "#..." views,
# the forms static/address.js reads (any other anchor would open the app's root)
LINK_RE = re.compile(r"https://\S+|/(?![/\\])\S*|#(?:sessions|schedules|machines|usage|new|search(?:\?\S*)?|side=\S*|(?:s|lane)=[^&\s]+)")


def die(msg, code=1):
    print("motion: " + msg, file=sys.stderr)
    sys.exit(code)


def now():
    v = os.environ.get("SALA_MOTION_NOW", "")
    try:
        return int(v) if v else int(time.time())
    except ValueError:
        return int(time.time())


def folder():
    d = os.environ.get("SALA_MOTION_DIR")
    if d:
        return d
    state = os.environ.get("SALA_STATE_DIR") or os.path.join(
        os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state"), "salamander")
    return os.path.join(state, "motion")


def chat_session():
    """The session SALA_CHAT_SESSION names, "" for none or a value that is no session name: the rule of sala-web (web/src/sala_web/config.py
    chat_session and sala_setting): the process environment when it is not empty, else the last `SALA_CHAT_SESSION=` line of sala's config file,
    read as text (quotes, an `export ` prefix and a trailing `# note` understood). `sala` sources that file before this runs, so what the file
    assigns counts over a value the caller's shell had, as it does for sala-web, whose service has no sala environment."""
    v = os.environ.get("SALA_CHAT_SESSION")
    if not v:
        v = ""
        path = os.environ.get("SALA_CONFIG") or os.path.join(os.path.expanduser("~"), ".config", "salamander", "config")
        try:
            with open(path, encoding="utf-8") as f:
                for line in f:
                    m = re.match(r"\s*(?:export\s+)?SALA_CHAT_SESSION=(.*)$", line.rstrip("\n"))
                    if m:
                        raw = m.group(1).strip()
                        if raw[:1] in ("'", '"'):
                            end = raw.find(raw[0], 1)
                            v = raw[1:end] if end > 0 else raw[1:]
                        else:
                            v = re.split(r"\s+#", raw, maxsplit=1)[0].strip()
        except (OSError, UnicodeDecodeError):
            v = ""
    v = v.strip()
    return v if NAME_RE.fullmatch(v) else ""


def clean_text(raw):
    """One line: control characters (U+0000-001F, U+007F-009F) out, the ones that break a line read as white space; runs of white space one
    space, ends trimmed. sala-web refuses a reply to a line that holds one of them."""
    breaks = "\t\r\n\v\f\x85"
    s = "".join(" " if ch in breaks else ch for ch in raw if ch in breaks or not (ch < " " or "\x7f" <= ch <= "\x9f"))
    return " ".join(s.split())


def link_ok(raw):
    """A result address (LINK_RE): an https address, an in-app path (/...) or one of the page's own anchors, no white space, at most LINK_MAX characters."""
    return len(raw) <= LINK_MAX and LINK_RE.fullmatch(raw) is not None


def load(path):
    """The listed lines (dicts with text and at; done and link when marked), oldest first; an unreadable or foreign file reads as none."""
    try:
        with open(path, encoding="utf-8") as f:
            doc = json.load(f)
    except (OSError, ValueError):
        return []
    rows = doc.get("lines") if isinstance(doc, dict) else None
    out = []
    for r in rows if isinstance(rows, list) else []:
        if not isinstance(r, dict) or not isinstance(r.get("text"), str) or isinstance(r.get("at"), bool) or not isinstance(r.get("at"), int):
            continue
        text = clean_text(r["text"])   # a line stored with a control character is cleaned by the next write
        if not text:
            continue
        row = {"text": text, "at": r["at"]}
        if isinstance(r.get("item"), str) and ITEM_RE.fullmatch(r["item"]):
            row["item"] = r["item"]
        if isinstance(r.get("done"), int) and not isinstance(r.get("done"), bool):
            row["done"] = r["done"]
            if isinstance(r.get("link"), str) and link_ok(r["link"]):
                row["link"] = r["link"]
        out.append(row)
    return out[:MAX_LINES]


def save(d, path, lines):
    tmp = "%s.tmp-%d" % (path, os.getpid())
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump({"v": 1, "lines": lines}, f, ensure_ascii=False)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)   # gone after the rename; left only when the write failed
        except OSError:
            pass


def main(argv):
    name = os.environ.get("SALA_MOTION_SELF", "")
    link = None
    item = None
    args = []
    as_json = False
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--for":
            if i + 1 >= len(argv):
                die("--for needs a session name", 2)
            name = argv[i + 1]
            i += 2
            continue
        if a.startswith("--for="):
            name = a[len("--for="):]
        elif a == "--link":
            if i + 1 >= len(argv):
                die("--link needs an address", 2)
            link = argv[i + 1]
            i += 2
            continue
        elif a.startswith("--link="):
            link = a[len("--link="):]
        elif a == "--item":
            if i + 1 >= len(argv):
                die("--item needs an item id", 2)
            item = argv[i + 1]
            i += 2
            continue
        elif a.startswith("--item="):
            item = a[len("--item="):]
        elif a == "--json":
            as_json = True
        else:
            args.append(a)
        i += 1
    if not args:
        die("usage: sala motion add \"<line>\" | done \"<line>\"|N [--link URL] | clear | list [--json]   [--for NAME]", 2)
    verb, rest = args[0], args[1:]
    if verb not in ("add", "done", "clear", "list"):
        die("unknown verb '%s' (add, done, clear, list)" % verb, 2)
    if as_json and verb != "list":
        die("--json is for list", 2)
    if link is not None and verb != "done":
        die("--link is for done", 2)
    if link is not None and not link_ok(link):
        die("--link takes an https address, an in-app path (/...) or one of the page's anchors (%s), without spaces, at most %d characters" % (LINK_FORMS, LINK_MAX), 2)
    if item is not None and verb != "add":
        die("--item is for add", 2)
    if item is not None and not ITEM_RE.fullmatch(item):
        die("--item takes a board item's id (letters, digits, # . _ -, at most 80 characters), like demo#12", 2)
    if not name:
        die("this is not run inside a session, so say whose lines these are: sala motion %s … --for NAME" % verb, 1)
    if not NAME_RE.fullmatch(name):
        die("'%s' is not a session name (letters, digits, dot, underscore, dash)" % name, 1)
    if verb in ("clear", "list") and rest:
        die("sala motion %s takes no argument" % verb, 2)
    if verb in ("add", "done") and len(rest) != 1:
        die("sala motion %s takes one argument (quote the line)" % verb, 2)

    chat = name == chat_session()   # only this session's lines are on a page, so only its done lines wait for the owner
    d = folder()
    os.makedirs(d, mode=0o700, exist_ok=True)
    os.chmod(d, 0o700)
    path = os.path.join(d, name + ".json")
    if verb == "list":   # a read: no lock needed, the file is replaced whole
        lines = load(path)
        if as_json:
            print(json.dumps([{"n": k + 1, "text": r["text"], "at": r["at"], "done": r.get("done"), "link": r.get("link"), "item": r.get("item")}
                              for k, r in enumerate(lines)], ensure_ascii=False))
        elif not lines:
            print("nothing right now")
        else:
            for k, r in enumerate(lines):
                state = "done, waiting for the owner's confirm or reply" if chat else "done, on no page: `done` or `clear` takes it off"
                mark = "  [%s]" % state if "done" in r else ""
                print("%d. %s%s" % (k + 1, r["text"], mark))
        return 0

    lock = os.open(os.path.join(d, ".lock"), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        lines = load(path)
        if verb == "clear":
            kept = [r for r in lines if chat and "done" in r]   # the owner has not acknowledged these: only he takes them off
            n = len(lines) - len(kept)
            save(d, path, kept)
            stays = "; %d done line%s kept until the owner confirms or replies on the chat page" % (len(kept), "" if len(kept) == 1 else "s") if kept else ""
            print("motion: cleared %d line%s for %s%s" % (n, "" if n == 1 else "s", name, stays))
            return 0
        if verb == "add":
            text = clean_text(rest[0])
            if not text:
                die("the line is empty")
            if len(text) > MAX_CHARS:
                die("the line is %d characters; at most %d (say it shorter)" % (len(text), MAX_CHARS))
            # `at` stays the time it was first added: the page says since when the work runs. A done line of the same text does not count: a new open line starts.
            same = [r for r in lines if r["text"] == text and "done" not in r]
            if same and item is not None and same[0].get("item") != item:
                same[0]["item"] = item
                save(d, path, lines)
                print("motion: already listed, its item is now %s (%d of %d)" % (item, len(lines), MAX_LINES))
                return 0
            if same:
                print("motion: already listed, nothing changed (%d of %d)" % (len(lines), MAX_LINES))
                return 0
            if len(lines) >= MAX_LINES and not chat:
                die("%d lines are already listed for %s (the most there is room for): take one off with `sala motion done N` or start over with `sala motion clear`" % (len(lines), name))
            if len(lines) >= MAX_LINES:
                die("%d lines are already listed for %s (the most there is room for, done ones included): wait for the owner to confirm or reply to a done one, or take the open ones off with `sala motion clear` (done ones stay)" % (len(lines), name))
            row = {"text": text, "at": now()}
            if item is not None:
                row["item"] = item
            lines.append(row)
            save(d, path, lines)
            print("motion: added (%d of %d): %s" % (len(lines), MAX_LINES, text))
            return 0
        # done: the chat session's line stays, marked, until the owner confirms it or replies to it on the page; another session's is taken off
        want = rest[0].strip()
        hit = None
        if re.fullmatch(r"[0-9]{1,3}", want):
            k = int(want)
            if 1 <= k <= len(lines):
                hit = k - 1
        if hit is None:
            exact = [k for k, r in enumerate(lines) if r["text"] == clean_text(want)]
            open_ = [k for k in exact if "done" not in lines[k]]   # a done line of the same text waits for the owner: the open one is the one meant
            if len(open_) == 1:
                hit = open_[0]
            elif exact and (len(exact) == 1 or not chat):
                hit = exact[0]
        if hit is None:
            die("no such line for %s: %s (see `sala motion list`)" % (name, want))
        row = lines[hit]
        if not chat:
            del lines[hit]
            save(d, path, lines)
            unkept = " (no page shows this session's lines, so the link is not kept)" if link is not None else ""
            print("motion: done: %s%s" % (row["text"], unkept))
            return 0
        if "done" in row:
            die("already done, waiting for the owner's confirm or reply: %s" % row["text"])
        row["done"] = now()
        if link is not None:
            row["link"] = link
        save(d, path, lines)
        where = ("its result link: " + link) if link is not None else "the page links the first chat reply at or after now"
        print("motion: done: %s; it waits in the owner's \"my turn\" list until he confirms it or replies to it (%s)" % (row["text"], where))
        return 0
    finally:
        os.close(lock)   # closing the descriptor releases the lock


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
