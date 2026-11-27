#!/usr/bin/env python3
"""lib/mockup.py — `sala mockup`: HTML mockups served by sala-web as numbered pages (docs/mockup.md).

A session that cannot publish an Artifact hands a reader a link instead of a picture: `sala mockup add page.html` stores the page under the
next number and prints https://<sala's address>/mockup/<n>; sala-web serves it behind the same sign-in as the rest of the site, in a sandbox
(web/README.md, *Mockup pages*). The pages are plain files, so nothing here asks a server anything.

  add FILE|-        store an HTML file (a path, or - for stdin) under the next number; prints the page's URL (stdout), nothing else
  update N FILE|-   a revision: replace stored page N in place (same number, same URL). The page it replaces is saved as a version first.
                    The same checks as add. A new page is `add`, never `update`; an unknown N is refused.
  history N         the saved versions of page N, newest first: when each was saved, its size
  undo N            restore the newest saved version of page N. The page it replaces is saved as a version too, so nothing is lost and
                    undoing again goes back to where it was
  list [--json]     the stored pages: number, size, age, URL
  remove [--force] N  delete one page with its versions (its number stays used). Refused when an open board item links it
                    (SALA_MOCKUP_REFERENCES), unless --force
  clean [--dry-run] [--days N] [--max-bytes N]   delete the pages older than N days (default SALA_MOCKUP_KEEP_DAYS, 7) unless an open board item
                    links them, then keep the folder under N bytes (default SALA_MOCKUP_MAX_BYTES, 1 GB = 1073741824): oldest page first, linked pages last

Storage: <state>/mockups/ (state = SALA_STATE_DIR, else $XDG_STATE_HOME/salamander), mode 700; <n>.html and `counter`, mode 600; and
versions/<n>/<UTC time>.html, one file for each version an update or an undo replaced (mode 600 in a mode 700 folder). The CLI is the only
writer; sala-web only reads. A number is taken under an exclusive lock on <dir>/.lock: the counter is raised and saved (write, fsync, rename)
BEFORE the page is written, so a crash leaves a gap and never a number given twice, and the counter keeps counting after a page is deleted.
A page is written to a temporary name and renamed, so a reader never sees half a page. A page is refused when it is empty, over 5 MiB, not
UTF-8 or holds a NUL byte (a mockup is text; the response says charset=utf-8, so another encoding would show as garbage), or when its visible text
letters its designs ("Variant A", "Option B": a design word and one capital letter; scripts, styles, comments and attributes do not count): name each
design instead, the same words as the board's options, so a letter here never meets a different letter there. There is no override: a name is always possible.

Address: the origin (scheme and host) of SALA_SESSION_URL, the link template sala already uses for a session's web link. Without it the path
(/mockup/<n>) is printed and a note on stderr says what to prefix it with.

Cleanup (`clean`, run daily by sala-mockup-clean.timer) applies two rules, in this order:
  1. a page is deleted when it is older than the keep time (its file's mtime, set when it was stored) and no open board item links it;
  2. when the folder (every file in it) still holds more than the cap, pages are deleted oldest first (mtime, then number) until it is under the cap;
     a page an open board item links goes last, and only when every unlinked page is already gone and the folder is still over.
A page's versions (versions/<n>/) are deleted with the page and count toward the folder's size; they are never listed; sala-web serves one only read-only, through its page (docs/mockup.md, *The history on the page*). The
versions of a page that is gone are deleted once they are older than the keep time.
Which pages the board links is read by a command the host names in SALA_MOCKUP_REFERENCES, because no supported read of the board gives a script
the text of its items without a model call:
  unset or empty   nothing is deleted by either rule: the pass keeps every page and says why (a host that has not said how to read the board loses nothing)
  none             no board item links a page: age and size alone decide (an explicit choice)
  <a command>      run without a shell (60 s); every `/mockup/<n>` in its output is a page an open item still links; a command that fails, times
                   out or prints nothing readable keeps every page (exit 1), because deleting on a failed read would lose a page somebody reads
Tests: SALA_MOCKUP_DIR (the folder), SALA_MOCKUP_NOW (the clock, epoch seconds), SALA_MOCKUP_TEMPLATE (the link template; the shell wrapper passes SALA_SESSION_URL's value).
Exit: 0 done (also a pass that kept pages for want of a way to read the board), 1 refused or failed, 2 usage.
"""
import fcntl
import html
import json
import os
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import time
from urllib.parse import urlsplit

MAX_BYTES = 5 * 1024 * 1024          # one page (the response is read whole, and a mockup that big is a mistake)
KEEP_DAYS_DEFAULT = 7
CAP_BYTES_DEFAULT = 1024 ** 3        # the folder's size limit: 1 GB (SALA_MOCKUP_MAX_BYTES, clean --max-bytes)
REF_TIMEOUT_S = 60
REF_MAX_BYTES = 8 * 1024 * 1024
TMP_MAX_AGE_S = 86400                # a half-written page older than this is a crash's leftover
PAGE_RE = re.compile(r"([1-9][0-9]*)\.html")
VERSIONS_DIR = "versions"
VERSION_RE = re.compile(r"(\d{8}T\d{6})\.(\d{6})Z\.html")   # one saved version: the UTC time it was saved, to the microsecond
VERSION_NUM_RE = re.compile(r"[1-9][0-9]*")
REF_RE = re.compile(r"/mockup/([1-9][0-9]{0,17})(?![0-9])")
VIEWPORT_RE = re.compile(r"<meta[^>]+name\s*=\s*[\"']?viewport", re.I)
# What a reader sees: script and style bodies, comments and tags are dropped first (an unterminated one runs to the end of the page).
HIDDEN_RE = re.compile(r"<script\b.*?(?:</script\s*>|\Z)|<style\b.*?(?:</style\s*>|\Z)|<!--.*?(?:-->|\Z)", re.I | re.S)
TAG_RE = re.compile(r"<[/!?]?[A-Za-z](?:\"[^\"]*\"|'[^']*'|[^'\">])*>")
# A design word and one capital letter standing alone ("Variant A", "Option B"). The Korean words are \u escapes only (a public repo holds no Hangul):
# U+C635 U+C158 (option), U+C2DC U+C548 (draft design), U+B514 U+C790 U+C778 (design), whitespace optional between word and letter.
LETTERED_RE = re.compile(
    r"(?<![A-Za-z0-9])(?i:variant|option|design|layout|proposal|alternative|concept|version|approach)[\s\u00a0]+[A-Z](?![A-Za-z0-9])"
    r"|(?:\uC635\uC158|\uC2DC\uC548|\uB514\uC790\uC778)[\s\u00a0]*[A-Z](?![A-Za-z0-9])")


class Refused(Exception):
    """A refusal with its sentence: printed after `sala mockup:`, exit 1."""


def now() -> float:
    v = os.environ.get("SALA_MOCKUP_NOW", "").strip()
    try:
        return float(v) if v else time.time()
    except ValueError:
        return time.time()


def state_dir() -> str:
    v = os.environ.get("SALA_STATE_DIR")
    if v:
        return v
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(base, "salamander")


def mockup_dir() -> str:
    return os.environ.get("SALA_MOCKUP_DIR") or os.path.join(state_dir(), "mockups")


def ensure_dir(d: str) -> None:
    os.makedirs(d, mode=0o700, exist_ok=True)
    os.chmod(d, 0o700)               # a umask or an older directory does not leave it wider


def write_atomic(path: str, data: bytes) -> None:
    """data to path through a temporary name in the same folder: fsync, then rename, mode 600. Nothing is left behind on a failure."""
    d = os.path.dirname(path)
    tmp = os.path.join(d, ".tmp-%d-%s" % (os.getpid(), secrets.token_hex(4)))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


class Locked:
    """An exclusive lock on <dir>/.lock for the length of a with block."""

    def __init__(self, d: str):
        ensure_dir(d)
        self.fd = os.open(os.path.join(d, ".lock"), os.O_RDWR | os.O_CREAT, 0o600)

    def __enter__(self):
        fcntl.flock(self.fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, *a):
        os.close(self.fd)            # closing drops the lock


def page_numbers(d: str) -> list:
    try:
        names = os.listdir(d)
    except OSError:
        return []
    return sorted(int(m.group(1)) for m in (PAGE_RE.fullmatch(n) for n in names) if m)


def read_counter(d: str) -> int:
    try:
        with open(os.path.join(d, "counter"), encoding="ascii") as f:
            return max(0, int(f.read().strip()))
    except (OSError, ValueError):
        return 0


def take_number(d: str) -> int:
    """The next number, with the counter saved. The caller holds the lock. The counter is never behind the highest page that exists."""
    n = max(read_counter(d), max(page_numbers(d) or [0])) + 1
    write_atomic(os.path.join(d, "counter"), b"%d\n" % n)
    return n


def check_page(data: bytes) -> str:
    """The page's text, or a Refused. Over MAX_BYTES, empty, a NUL byte, not UTF-8 or lettering its designs is refused."""
    if not data.strip():
        raise Refused("the file is empty")
    if len(data) > MAX_BYTES:
        raise Refused("the page is over %d MiB (%d bytes read): a mockup that big needs trimming first" % (MAX_BYTES >> 20, len(data)))
    if b"\0" in data:
        raise Refused("the file holds a NUL byte: it is not an HTML text file")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as e:
        raise Refused("the file is not UTF-8 (byte %d): save it as UTF-8, the page is served as text/html; charset=utf-8" % e.start)
    found = lettered_designs(text)
    if found:
        raise Refused("the page letters its designs (%s): name each design instead (One-line strip, Fuller panel), the same words as the board's options, "
                      "so a letter here never meets a different letter there" % ", ".join('"%s"' % f for f in found))
    return text


def lettered_designs(text: str) -> list:
    """Up to 3 distinct phrases of the page's visible text that letter a design ("Variant A", "Option B"), as the page words them."""
    visible = html.unescape(TAG_RE.sub(" ", HIDDEN_RE.sub(" ", text)))
    found = []
    for m in LETTERED_RE.finditer(visible):
        phrase = " ".join(m.group(0).split())
        if phrase not in found:
            found.append(phrase)
            if len(found) == 3:
                break
    return found


def base_url() -> str:
    """scheme://host of SALA_SESSION_URL's template, or '' when it names no web address."""
    tpl = os.environ.get("SALA_MOCKUP_TEMPLATE", "").strip()
    try:
        u = urlsplit(tpl)
    except ValueError:
        return ""
    return "%s://%s" % (u.scheme, u.netloc) if u.scheme in ("http", "https") and u.netloc else ""


def url_of(n: int) -> str:
    return "%s/mockup/%d" % (base_url(), n)


def read_source(path: str) -> bytes:
    """The bytes of FILE (a path, or - for standard input), at most MAX_BYTES + 1 of them (check_page refuses the bigger ones)."""
    if path == "-":
        return sys.stdin.buffer.read(MAX_BYTES + 1)
    try:
        if not os.path.isfile(path):
            raise Refused("%s is not a file" % path)
        with open(path, "rb") as f:
            return f.read(MAX_BYTES + 1)
    except OSError as e:
        raise Refused("cannot read %s: %s" % (path, e.strerror or e))


def notes(text: str) -> None:
    if not VIEWPORT_RE.search(text):
        print("sala mockup: note: the page has no <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">; "
              "a phone shows it zoomed out until it has one", file=sys.stderr)
    if not base_url():
        print("sala mockup: note: SALA_SESSION_URL is not set, so this is the path only: put your sala address in front of it", file=sys.stderr)


def versions_dir(d: str, n: int) -> str:
    return os.path.join(d, VERSIONS_DIR, "%d" % n)


def version_files(vdir: str) -> list:
    """The version file names in a page's folder, oldest first (the names sort by time)."""
    try:
        names = os.listdir(vdir)
    except OSError:
        return []
    return sorted(n for n in names if VERSION_RE.fullmatch(n))


def save_version(d: str, n: int, data: bytes) -> None:
    """Save `data` as a new version of page n, named by the time now, later than every version already there (two in one
    microsecond still get two names). The caller holds the lock. Mode 600 in a mode 700 folder, written atomically."""
    vdir = versions_dir(d, n)
    ensure_dir(os.path.join(d, VERSIONS_DIR))
    ensure_dir(vdir)
    names = set(version_files(vdir))
    last = max(names, default="")
    us = int(round(now() * 1000000))
    while True:
        name = time.strftime("%Y%m%dT%H%M%S", time.gmtime(us // 1000000)) + ".%06dZ.html" % (us % 1000000)
        if name not in names and name > last:
            break
        us += 1
    write_atomic(os.path.join(vdir, name), data)


def stamp_of(name: str) -> str:
    m = VERSION_RE.fullmatch(name)
    t, us = m.group(1), m.group(2)
    return "%s-%s-%s %s:%s:%s.%s UTC" % (t[0:4], t[4:6], t[6:8], t[9:11], t[11:13], t[13:15], us)


def add(path: str) -> int:
    data = read_source(path)
    text = check_page(data)
    d = mockup_dir()
    with Locked(d):
        n = take_number(d)
        write_atomic(os.path.join(d, "%d.html" % n), data)
    notes(text)
    print(url_of(n))
    return 0


def update(num: str, path: str) -> int:
    """Replace stored page N in place: the page it replaces is saved as a version first, then the new page is renamed over N.html.
    Both writes are atomic and under the lock; a crash between them leaves the old page in its versions, never a lost one."""
    n = int(num)
    data = read_source(path)
    text = check_page(data)
    d = mockup_dir()
    with Locked(d):
        cur = os.path.join(d, "%d.html" % n)
        try:
            with open(cur, "rb") as f:
                old = f.read()
        except FileNotFoundError:
            raise Refused("no page %d to update: a new page is `add`; `update` only revises a page that exists" % n)
        except OSError as e:
            raise Refused("cannot read page %d: %s" % (n, e.strerror or e))
        save_version(d, n, old)
        write_atomic(cur, data)
    notes(text)
    print(url_of(n))
    return 0


def undo(num: str) -> int:
    """Restore page N's newest saved version. The page it replaces is saved as a version first, and the restored one is deleted from
    the versions, so undoing again goes back to where it was and nothing is ever lost."""
    n = int(num)
    d = mockup_dir()
    with Locked(d):
        cur = os.path.join(d, "%d.html" % n)
        try:
            with open(cur, "rb") as f:
                now_data = f.read()
        except FileNotFoundError:
            raise Refused("no page %d" % n)
        names = version_files(versions_dir(d, n))
        if not names:
            raise Refused("page %d has no earlier version to go back to (only an update or an undo keeps one)" % n)
        newest = os.path.join(versions_dir(d, n), names[-1])
        with open(newest, "rb") as f:
            before = f.read()
        save_version(d, n, now_data)
        write_atomic(cur, before)
        os.unlink(newest)
    print(url_of(n))
    return 0


def cmd_history(args: list) -> int:
    if len(args) != 1 or not VERSION_NUM_RE.fullmatch(args[0]):
        raise Usage("history N")
    vdir = versions_dir(mockup_dir(), int(args[0]))
    for name in reversed(version_files(vdir)):
        try:
            size = os.stat(os.path.join(vdir, name)).st_size
        except OSError:
            continue
        print("%s	%d bytes	%s" % (stamp_of(name), size, name))
    return 0


def age_words(secs: float) -> str:
    secs = max(0, int(secs))
    if secs >= 86400:
        return "%dd" % (secs // 86400)
    if secs >= 3600:
        return "%dh" % (secs // 3600)
    return "%dm" % (secs // 60)


def rows(d: str) -> list:
    out = []
    t = now()
    for n in page_numbers(d):
        try:
            st = os.stat(os.path.join(d, "%d.html" % n))
        except OSError:
            continue
        out.append({"n": n, "bytes": st.st_size, "stored": int(st.st_mtime), "ageSeconds": int(t - st.st_mtime), "url": url_of(n)})
    return out


def cmd_list(args: list) -> int:
    as_json = "--json" in args
    if [a for a in args if a != "--json"]:
        raise Usage("list [--json]")
    rs = rows(mockup_dir())
    if as_json:
        print(json.dumps(rs))
    else:
        for r in rs:
            print("%d\t%d bytes\t%s old\t%s" % (r["n"], r["bytes"], age_words(r["ageSeconds"]), r["url"]))
    return 0


class Usage(Exception):
    pass


def cmd_remove(args: list) -> int:
    force = args.count("--force") == 1
    rest = [a for a in args if a != "--force"]
    if len(rest) != 1 or not re.fullmatch(r"[1-9][0-9]*", rest[0]) or len(args) != len(rest) + (1 if force else 0):
        raise Usage("remove [--force] N")
    n = int(rest[0])
    spec = os.environ.get("SALA_MOCKUP_REFERENCES", "")
    if not force and spec.strip():
        # an open board item links the page: refuse (a command that fails refuses too, since it cannot say); unset or empty removes as before
        try:
            linked = referenced(spec)
        except Refused as e:
            raise Refused("%s; not removed (remove --force %d removes it without the check)" % (e, n))
        if n in linked:
            raise Refused("page %d is linked by an open board item; remove it anyway with `remove --force %d`" % (n, n))
    d = mockup_dir()
    with Locked(d):
        try:
            os.unlink(os.path.join(d, "%d.html" % n))
        except FileNotFoundError:
            raise Refused("no page %d" % n)
        shutil.rmtree(versions_dir(d, n), ignore_errors=True)
    print("removed %d" % n)
    return 0


def referenced(spec: str) -> set:
    """The page numbers an open board item links, as the host's command says (SALA_MOCKUP_REFERENCES); a Refused when it cannot say."""
    if spec.strip().lower() == "none":
        return set()
    try:
        argv = shlex.split(spec)
    except ValueError as e:
        raise Refused("SALA_MOCKUP_REFERENCES is not a command line (%s)" % e)
    if not argv:
        raise Refused("SALA_MOCKUP_REFERENCES is empty")
    argv[0] = os.path.expanduser(argv[0])
    try:
        r = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, timeout=REF_TIMEOUT_S)
    except FileNotFoundError:
        raise Refused("the SALA_MOCKUP_REFERENCES command was not found: %s" % argv[0])
    except subprocess.TimeoutExpired:
        raise Refused("the SALA_MOCKUP_REFERENCES command took over %d s" % REF_TIMEOUT_S)
    except OSError as e:
        raise Refused("the SALA_MOCKUP_REFERENCES command could not run: %s" % (e.strerror or e))
    if r.returncode != 0:
        raise Refused("the SALA_MOCKUP_REFERENCES command exited %d" % r.returncode)
    if len(r.stdout) > REF_MAX_BYTES:
        raise Refused("the SALA_MOCKUP_REFERENCES command printed over %d MiB" % (REF_MAX_BYTES >> 20))
    return {int(m) for m in REF_RE.findall(r.stdout.decode("utf-8", "replace"))}


def folder_bytes(d: str) -> int:
    """What a folder holds: every regular file under it (pages, versions, the counter, a half-written page)."""
    total = 0
    for root, _dirs, files in os.walk(d):
        for name in files:
            try:
                total += os.stat(os.path.join(root, name), follow_symlinks=False).st_size
            except OSError:
                pass
    return total


def page_bytes(d: str, n: int) -> int:
    """A page with its versions: what deleting it frees."""
    total = folder_bytes(versions_dir(d, n))
    try:
        total += os.stat(os.path.join(d, "%d.html" % n), follow_symlinks=False).st_size
    except OSError:
        pass
    return total


def clean(d: str, t: float, keep_days: float, spec: str, cap: int = CAP_BYTES_DEFAULT, dry_run: bool = False, say=print) -> int:
    """One cleanup pass at time t. Returns the exit status. `spec` is SALA_MOCKUP_REFERENCES's value, `cap` the folder's size limit in bytes
    (see the module text for the two rules and their order)."""
    cutoff = t - keep_days * 86400
    pages = {}                                   # number -> (mtime, size of the page and its versions)
    for n in page_numbers(d):
        try:
            st = os.stat(os.path.join(d, "%d.html" % n))
        except OSError:
            continue
        pages[n] = (st.st_mtime, page_bytes(d, n))
    # a crash's leftovers: a temporary page older than a day
    try:
        for name in os.listdir(d):
            p = os.path.join(d, name)
            if name.startswith(".tmp-") and t - os.stat(p).st_mtime > TMP_MAX_AGE_S and not dry_run:
                os.unlink(p)
    except OSError:
        pass
    old = sorted(n for n, (m, _) in pages.items() if m < cutoff)
    total = folder_bytes(d)
    over = total > cap
    if not old and not over:
        say("mockup clean: no page is older than %g days and the folder holds %d of %d bytes; nothing to do" % (keep_days, total, cap))
        return 0
    if not spec.strip():
        say("mockup clean: kept all %d page(s): SALA_MOCKUP_REFERENCES is not set, so there is no way to tell which an open board item still links. "
            "%s%sSet it to a command that prints the board's open items (every /mockup/<n> in its output is kept), or to none to treat no page as linked"
            % (len(pages),
               ("%d older than %g days (%s). " % (len(old), keep_days, ", ".join(map(str, old)))) if old else "",
               ("The folder holds %d bytes, over the %d byte cap. " % (total, cap)) if over else ""))
        return 0
    try:
        keep = referenced(spec)
    except Refused as e:
        say("mockup clean: kept all %d page(s): %s" % (len(pages), e))
        return 1
    gone, left = [], dict(pages)

    def drop(n: int, why: str) -> None:
        nonlocal total
        if dry_run:
            say("mockup clean: would delete %d (%s)" % (n, why))
        else:
            try:
                os.unlink(os.path.join(d, "%d.html" % n))
            except FileNotFoundError:
                pass
            except OSError as e:
                say("mockup clean: could not delete %d: %s" % (n, e.strerror or e))
                return
            shutil.rmtree(versions_dir(d, n), ignore_errors=True)
            say("mockup clean: deleted %d (%s)" % (n, why))
        total -= left.pop(n)[1]
        gone.append(n)

    with Locked(d):
        # the versions of a page that is gone belong to nothing: delete them once they are past the keep time
        vroot = os.path.join(d, VERSIONS_DIR)
        orphans = []
        if not dry_run and os.path.isdir(vroot):
            orphans = [int(x) for x in os.listdir(vroot) if VERSION_NUM_RE.fullmatch(x)]
        for n in sorted(orphans):
            if os.path.exists(os.path.join(d, "%d.html" % n)):
                continue
            vdir = versions_dir(d, n)
            for name in version_files(vdir):
                p = os.path.join(vdir, name)
                try:
                    if t - os.stat(p).st_mtime > keep_days * 86400:
                        os.unlink(p)
                        say("mockup clean: deleted a version of %d (its page is gone): %s" % (n, name))
                except OSError:
                    pass
            try:
                os.rmdir(vdir)
            except OSError:
                pass
        total = folder_bytes(d)
        # rule 1: older than the keep time, unless an open board item links it
        for n in old:
            if n in keep:
                say("mockup clean: kept %d: an open board item links it" % n)
            else:
                drop(n, "older than %g days" % keep_days)
        # rule 2: over the cap, oldest first; a page an open board item links goes last, and only if every other page is gone and it is still over
        if total > cap:
            order = sorted(left, key=lambda n: (n in keep, left[n][0], n))
            for n in order:
                if total <= cap:
                    break
                drop(n, "folder over its %d byte cap%s" % (cap, ", linked by an open board item: last resort" if n in keep else ""))
            if total > cap:
                say("mockup clean: the folder still holds %d bytes, over the %d byte cap, with no page left to delete" % (total, cap))
    say("mockup clean: %s %d page(s); %d page(s), %d bytes left (cap %d)" % ("would delete" if dry_run else "deleted", len(gone), len(left), total, cap))
    return 0


def cmd_clean(args: list) -> int:
    form = "clean [--dry-run] [--days N] [--max-bytes N]"
    dry, days, cap = False, None, None
    i = 0
    while i < len(args):
        if args[i] == "--dry-run":
            dry = True
        elif args[i] in ("--days", "--max-bytes") and i + 1 < len(args):
            flag = args[i]
            i += 1
            try:
                v = float(args[i])
            except ValueError:
                raise Usage(form)
            if v < 0:
                raise Usage(form)
            if flag == "--days":
                days = v
            else:
                cap = int(v)
        else:
            raise Usage(form)
        i += 1
    if days is None:
        try:
            days = float(os.environ.get("SALA_MOCKUP_KEEP_DAYS", "") or KEEP_DAYS_DEFAULT)
        except ValueError:
            raise Refused("SALA_MOCKUP_KEEP_DAYS is not a number")
        if days < 0:
            raise Refused("SALA_MOCKUP_KEEP_DAYS is negative")
    if cap is None:
        try:
            cap = int(float(os.environ.get("SALA_MOCKUP_MAX_BYTES", "") or CAP_BYTES_DEFAULT))
        except ValueError:
            raise Refused("SALA_MOCKUP_MAX_BYTES is not a number")
        if cap < 0:
            raise Refused("SALA_MOCKUP_MAX_BYTES is negative")
    d = mockup_dir()
    if not os.path.isdir(d):
        print("mockup clean: no mockup folder yet; nothing to do")
        return 0
    return clean(d, now(), days, os.environ.get("SALA_MOCKUP_REFERENCES", ""), cap, dry)


USAGE = {
    "add": "add FILE|-",
    "update": "update N FILE|-",
    "history": "history N",
    "undo": "undo N",
    "list": "list [--json]",
    "remove": "remove [--force] N",
    "clean": "clean [--dry-run] [--days N] [--max-bytes N]",
}


def main(argv: list) -> int:
    try:
        verb = argv[0] if argv else ""
        if verb == "add" and len(argv) == 2 and (argv[1] == "-" or not argv[1].startswith("-")):
            return add(argv[1])
        if verb == "update" and len(argv) == 3 and re.fullmatch(r"[1-9][0-9]*", argv[1]) and (argv[2] == "-" or not argv[2].startswith("-")):
            return update(argv[1], argv[2])
        if verb == "history":
            return cmd_history(argv[1:])
        if verb == "undo" and len(argv) == 2 and re.fullmatch(r"[1-9][0-9]*", argv[1]):
            return undo(argv[1])
        if verb == "list":
            return cmd_list(argv[1:])
        if verb == "remove":
            return cmd_remove(argv[1:])
        if verb == "clean":
            return cmd_clean(argv[1:])
        if verb in USAGE:
            raise Usage(USAGE[verb])
        raise Usage("add FILE|- | update N FILE|- | history N | undo N | list | remove [--force] N | clean")
    except Usage as e:
        print("usage: sala mockup %s" % e, file=sys.stderr)
        return 2
    except Refused as e:
        print("sala mockup: %s" % e, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
