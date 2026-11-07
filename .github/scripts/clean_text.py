#!/usr/bin/env python3
"""clean_text.py: refuses private data in the text a pull request puts on GitHub (CONTRIBUTING.md, "Clean commit and PR text").

Scans the head branch name, the PR title, the PR body and the message of every non-merge commit in base..head. Every hit is
printed as `<where>: <the matched text> (<rule>)`, one per line, and the exit status is 1. The PR body is never echoed whole:
only the matched text is.

Rules (case-insensitive):
  board id      board#<digits> and board-tmp-<word>#<digits>. A bare #<digits> is GitHub's own PR and issue reference: fine.
  deny list     one case-insensitive Python regex per line of the repository SECRET CLEAN_TEXT_DENY (newline-separated only: a
                comma can be part of a regex; blank lines and # comment lines are skipped; a plain word is a regex too). Each is
                matched on ASCII word boundaries ([A-Za-z0-9_], so `nameé` is a hit); a hyphen continues a word only with a word
                character on its other side (`box-1-ci` is another name, `--box-1` and `box-1-` are the name). They are private
                names, so they live in the secret (a secret and not a variable: only secrets are masked in a job's log) and never
                in this repository (the code holds no owner value). Unset or empty: that rule is skipped and one notice line says so. A line that is not a valid regex exits 2, naming the source and the line number.
Allowed and left out of the scan: `Co-Authored-By:` lines and a Claude session URL (https://claude.ai/code/session_...).

Usage (stdlib only; run it with `python3 -I`):
  CI (tests.yml's sibling, .github/workflows/clean-text.yml), everything through the environment:
    CLEAN_TEXT_BRANCH, CLEAN_TEXT_TITLE, CLEAN_TEXT_BODY (all three must be present; empty is fine), CLEAN_TEXT_BASE,
    CLEAN_TEXT_HEAD (the two shas), CLEAN_TEXT_BASE_REF (the base branch name, optional), CLEAN_TEXT_DENY
    The commits scanned are refs/remotes/origin/<CLEAN_TEXT_BASE_REF>..head, fetched fresh (a 120 s limit, CLEAN_TEXT_FETCH_TIMEOUT
    to change it), so a branch that merged the base back in is not blamed for the base's older commits;
    CLEAN_TEXT_BASE..head when the name is absent or the fetch fails or times out.
  Locally, on the branch you are about to push, from inside the worktree:
    python3 -I .github/scripts/clean_text.py --local origin/main [--title TEXT] [--body-file FILE|-]
  --local <base> takes the branch name from the current branch and the commits from `git log --no-merges <base>..HEAD`; a title
  and a body are scanned only when given (--title / CLEAN_TEXT_TITLE, --body-file / CLEAN_TEXT_BODY).
  The client-side hooks (.githooks/, enabled with `git config core.hooksPath .githooks`), which refuse the same text before it
  is committed or pushed:
    --message-file PATH   commit-msg: the message in PATH, without the # lines git drops; a merge commit's message is skipped
    --push [REMOTE]       pre-push: git's stdin lines (<local ref> <local sha> <remote ref> <remote sha>); per pushed ref the branch
                          name and the non-merge commits the remote lacks (remote sha..local sha; for a new branch, those no
                          refs/remotes/REMOTE/* branch reaches); a deletion is skipped
  Deny words: in CI, CLEAN_TEXT_DENY alone (the repository secret). Everywhere else (--local and the hooks) CLEAN_TEXT_DENY when
  it holds a pattern, else the file $XDG_CONFIG_HOME/salamander/clean-text-deny (default ~/.config/...), one regex per line, a line
  that starts with # is a comment. Neither: that rule is skipped with the notice line, the other rules still run.
Exit status: 0 clean, 1 a hit, 2 a call that cannot be answered (a missing input, git failing): the check never passes on a
text it could not read.
"""
import argparse
import os
import re
import signal
import subprocess
import sys

FLAGS = re.IGNORECASE
W = "[A-Za-z0-9_]"   # ASCII only, in every rule: a hit with a non-ASCII letter directly before or after it (`nameé`, `énode`) is still a hit
RULES = [
    ("board id", re.compile(r"(?<!%s)(?:board-tmp-[A-Za-z0-9_-]+#\d+|board#\d+)" % W, FLAGS)),
]
ALLOWED_LINE = re.compile(r"^\s*co-authored-by:.*$", FLAGS)
ALLOWED_URL = re.compile(r"https://claude\.ai/code/session_[\w-]+", FLAGS)
NOTICE_UNSET = "clean-text: notice: CLEAN_TEXT_DENY is not set or empty, so the deny check (the private names) is skipped"


def deny_lines(raw):
    """(line number, text) of each line of a deny list that holds a pattern: blank lines and # comment lines are skipped."""
    return [(n, ln.strip()) for n, ln in enumerate((raw or "").split("\n"), 1) if ln.strip() and not ln.strip().startswith("#")]


def deny_rule(raw, source):
    """The deny list as a list of compiled regexes, one per line (empty when it holds no pattern). Each line is a case-insensitive
    Python regex (a plain word is one), wrapped in the word boundaries. A hyphen continues a word only when a word character is on
    its other side: `box-1-ci` is another name, but `--box-1` and `box-1-` (a trailing dash) are the name itself. A line that is not a
    valid regex exits 2, naming the source and the line number, never the line."""
    rxs = []
    for n, pat in deny_lines(raw):
        try:
            re.compile(pat, FLAGS)   # on its own first: a line like `a)|(b` is invalid, not a way past the boundaries
            rxs.append(re.compile(r"(?<!%s)(?<!%s-)(?:%s)(?!%s)(?!-%s)" % (W, W, pat, W, W), FLAGS))
        except (re.error, RecursionError, OverflowError):
            sys.stderr.write("clean-text: %s line %d is not a valid regular expression\n" % (source, n))
            sys.exit(2)
    return rxs


def printable(text):
    return "".join(c if c.isprintable() else "?" for c in text)


def scan(where, text, rules):
    """The hits of one text, one (where, matched, rule) per match; the allowed forms are blanked first, line numbers kept."""
    hits = []
    lines = (text or "").splitlines()
    multi = len(lines) > 1
    for n, line in enumerate(lines, 1):
        if ALLOWED_LINE.match(line):
            continue
        line = ALLOWED_URL.sub("", line)
        seen = set()
        for name, rx in rules:
            for m in rx.finditer(line):
                if (m.span(), name) in seen:   # two deny lines that match the same text report it once
                    continue
                seen.add((m.span(), name))
                hits.append(("%s line %d" % (where, n) if multi else where, printable(m.group(0)), name))
    return hits


def git(*args):
    p = subprocess.run(["git", *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                       encoding="utf-8", errors="replace")
    if p.returncode != 0:
        err = p.stderr.strip().splitlines()
        sys.stderr.write("clean-text: git %s failed: %s\n" % (" ".join(args[:2]), err[-1] if err else "no message"))
        sys.exit(2)
    return p.stdout


def range_base(sha, ref):
    """What the commit range starts from. With the PR's base branch name, refs/remotes/origin/<ref> fetched fresh (named in full, so
    a tag or a branch of the same short name cannot stand in for it): a branch that merged the base back in is then not blamed for
    the base's own older commits. The base sha (the base as the PR was opened or last updated) is the fallback when there is no
    name or the fetch (CLEAN_TEXT_FETCH_TIMEOUT seconds, 120 by default) or the lookup fails."""
    if ref:
        rev = "refs/remotes/origin/%s" % ref
        quiet = dict(stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        why = "cannot fetch"
        try:
            limit = float(os.environ.get("CLEAN_TEXT_FETCH_TIMEOUT") or 120)
        except ValueError:
            limit = 120.0
        # its own process group, so a timeout ends the transport helpers git starts as well
        p = subprocess.Popen(["git", "fetch", "--quiet", "origin", "+refs/heads/%s:%s" % (ref, rev)],
                             start_new_session=True, **quiet)
        try:
            p.communicate(timeout=limit)
            fetched = p.returncode == 0
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
            p.communicate()
            fetched, why = False, "timed out fetching"
        if fetched and subprocess.run(["git", "rev-parse", "--verify", "--quiet", rev + "^{commit}"], **quiet).returncode == 0:
            return rev
        sys.stderr.write("clean-text: %s origin/%s, scanning from the base sha instead\n" % (why, ref))
    return sha


def log_commits(*revs):
    """(short sha, message) for every non-merge commit the revision arguments select."""
    out = git("log", "-z", "--no-merges", "--format=%H%x1f%B", *revs)
    res = []
    for rec in out.split("\0"):
        if not rec.strip():
            continue
        sha, _, msg = rec.partition("\x1f")
        res.append((sha.strip()[:7], msg))
    return res


def commits(base, head):
    """(short sha, message) for every non-merge commit in base..head."""
    return log_commits("%s..%s" % (base, head))


def local_deny(env):
    """The deny list outside CI: CLEAN_TEXT_DENY when it holds a pattern, else the owner's own file (one regex per line, # lines
    are comments) at $XDG_CONFIG_HOME/salamander/clean-text-deny. Returns (text, its source name, the file's path)."""
    raw = env.get("CLEAN_TEXT_DENY")
    path = os.path.join(env.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), "salamander", "clean-text-deny")
    if deny_lines(raw):
        return raw, "CLEAN_TEXT_DENY", path
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read(), path, path
    except OSError:
        return "", path, path


def build_rules(env, local):
    """The rules to apply, and the one notice line when the deny list is empty. `local` = a hook or --local run, which also
    reads the deny file."""
    rules = list(RULES)
    raw, source, path = local_deny(env) if local else (env.get("CLEAN_TEXT_DENY"), "CLEAN_TEXT_DENY", None)
    deny = deny_rule(raw, source)
    if deny:
        rules.extend(("deny list", rx) for rx in deny)
    else:
        print(NOTICE_UNSET + ("" if path is None else " (no deny file at %s either)" % path))
    return rules


def report(hits, what):
    """Print the hits, one per line, then the verdict; the exit status."""
    for where, text, rule in hits:
        print("%s: %s (%s)" % (where, text, rule))
    if hits:
        print("clean-text: %d hit(s). Rewrite the text without them (CONTRIBUTING.md, \"Clean commit and PR text\")." % len(hits))
        return 1
    print("clean-text: clean (%s)" % what)
    return 0


SCISSORS = "# ------------------------ >8 ------------------------"


def check_message(path, env):
    """The commit-msg hook: the message file git hands over, minus what git itself drops (# lines, and everything under the
    scissors line `git commit -v` adds). A merge commit's message is not scanned, as in CI."""
    if subprocess.run(["git", "rev-parse", "-q", "--verify", "MERGE_HEAD"],
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
        return 0
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError as e:
        sys.stderr.write("clean-text: cannot read the message file: %s\n" % e.strerror)
        return 2
    kept = []
    for ln in lines:
        if ln.rstrip() == SCISSORS:
            break
        if not ln.startswith("#"):
            kept.append(ln)
    rules = build_rules(env, True)
    return report(scan("message", "\n".join(kept), rules), "commit message")


def has_commit(sha):
    return subprocess.run(["git", "cat-file", "-e", sha + "^{commit}"],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def check_push(remote, env):
    """The pre-push hook: git's stdin lines `<local ref> <local sha> <remote ref> <remote sha>`. For each pushed ref, the branch
    (or tag) name and the non-merge commits the remote does not have yet: remote sha..local sha, or for a new branch the commits
    no remote-tracking branch of that remote reaches. A deletion pushes no text and passes."""
    pushed = []
    for line in sys.stdin.read().splitlines():
        parts = line.split()
        if len(parts) >= 4:
            pushed.append(parts[:4])
    rules = build_rules(env, True)
    hits, seen, nrefs = [], set(), 0
    for _lref, lsha, rref, rsha in pushed:
        if set(lsha) == {"0"}:
            continue
        nrefs += 1
        m = re.match(r"refs/(heads|tags)/(.*)", rref)
        hits += scan("branch" if m and m.group(1) == "heads" else "tag" if m else "ref", m.group(2) if m else rref, rules)
        if set(rsha) != {"0"} and has_commit(rsha):
            revs = [lsha, "--not", rsha]
        else:
            # git passes a URL, not a name, when the push names none: then every remote-tracking branch counts
            revs = [lsha, "--not", "--remotes=%s" % remote if re.fullmatch(r"[\w.-]+", remote) else "--remotes"]
        for sha, msg in log_commits(*revs):
            if sha not in seen:
                seen.add(sha)
                hits += scan("commit %s" % sha, msg, rules)
    return report(hits, "%d ref%s and %d commit message%s pushed" % (nrefs, "" if nrefs == 1 else "s", len(seen), "" if len(seen) == 1 else "s"))


def main(argv):
    ap = argparse.ArgumentParser(prog="clean_text.py", add_help=True, description="refuse private data in commit and PR text")
    ap.add_argument("--local", metavar="BASE", help="scan this checkout's branch and the commits in BASE..HEAD")
    ap.add_argument("--title", help="the PR title to scan (default: CLEAN_TEXT_TITLE)")
    ap.add_argument("--body-file", metavar="FILE", help="a file holding the PR body to scan, - for stdin (default: CLEAN_TEXT_BODY)")
    ap.add_argument("--message-file", metavar="PATH", help="the commit-msg hook: scan the commit message in this file")
    ap.add_argument("--push", nargs="?", const="origin", metavar="REMOTE",
                    help="the pre-push hook: scan what git's stdin lines say is being pushed to REMOTE (default origin)")
    args = ap.parse_args(argv)
    env = os.environ
    sys.stdout.reconfigure(errors="replace")   # a hit's text can be any character; a C-locale stdout must not crash on it
    if args.message_file is not None:
        return check_message(args.message_file, env)
    if args.push is not None:
        return check_push(args.push, env)

    if args.local:
        base, head = args.local, "HEAD"
        branch = git("rev-parse", "--abbrev-ref", "HEAD").strip()
        if branch == "HEAD":
            branch = ""   # a detached HEAD has no branch name to scan
    else:
        # present, not non-empty: an empty title or body is a real value, an absent one means the workflow did not pass it
        need = ("CLEAN_TEXT_BASE", "CLEAN_TEXT_HEAD", "CLEAN_TEXT_BRANCH", "CLEAN_TEXT_TITLE", "CLEAN_TEXT_BODY")
        missing = [k for k in need if k not in env]
        if missing:
            sys.stderr.write("clean-text: missing %s (see --help)\n" % ", ".join(missing))
            return 2
        head, branch = env["CLEAN_TEXT_HEAD"], env["CLEAN_TEXT_BRANCH"]
        base = range_base(env["CLEAN_TEXT_BASE"], env.get("CLEAN_TEXT_BASE_REF"))
    title = args.title if args.title is not None else env.get("CLEAN_TEXT_TITLE")
    if args.body_file is not None:
        try:
            body = sys.stdin.read() if args.body_file == "-" else open(args.body_file, encoding="utf-8").read()
        except OSError as e:
            sys.stderr.write("clean-text: cannot read the body file: %s\n" % e.strerror)
            return 2
    else:
        body = env.get("CLEAN_TEXT_BODY")

    rules = build_rules(env, bool(args.local))

    hits = []
    hits += scan("branch", branch, rules)
    hits += scan("title", title, rules)
    hits += scan("body", body, rules)
    ncommits = 0
    for sha, msg in commits(base, head):
        ncommits += 1
        hits += scan("commit %s" % sha, msg, rules)

    return report(hits, "branch, title, body and %d commit message%s" % (ncommits, "" if ncommits == 1 else "s"))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
