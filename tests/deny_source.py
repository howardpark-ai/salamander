#!/usr/bin/env python3
"""deny_source.py: the tests' reader of the clean-text deny source, so a suite never carries an owner's private value itself.

The deny source is the one .github/scripts/clean_text.py reads outside CI: $CLEAN_TEXT_DENY when it holds a pattern, else the file
$XDG_CONFIG_HOME/salamander/clean-text-deny (default ~/.config/...). Its lines are matched exactly as clean_text.py matches them
(clean_text.deny_rule: case-insensitive regexes on word boundaries). Nothing here prints a pattern or the text a pattern matched:
the answers are counts, line numbers of the scanned text and file names.

Run it with `python3 -I`. The shell side is tests/lib.sh (deny_load, deny_have, deny_count, deny_at, deny_files).
  dump OUT              write the deny source's text to OUT (mode 600); exit 0, or 1 when there is no pattern at all (nothing written);
                        a line that is not a valid regex exits 2 (clean_text's own message, naming the line number only)
  hits DENYFILE [PATH]  print `<count> <line numbers, comma separated>` for the lines of PATH (default - = stdin) that match a rule
  files DENYFILE        read file names from stdin (one per line), print those that hold a match
As a module (tests that run their own Python): Deny(path).search(text) is a match or None.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".github", "scripts"))
import clean_text  # noqa: E402


class Deny:
    """The rules of a deny file, one compiled regex per pattern line."""

    def __init__(self, path):
        with open(path, encoding="utf-8", errors="replace") as f:
            self.rules = clean_text.deny_rule(f.read(), "the deny file")

    def search(self, text):
        for rx in self.rules:
            m = rx.search(text)
            if m:
                return m
        return None


def _lines(path):
    if path == "-":
        return sys.stdin.read().split("\n")
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read().split("\n")


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__)
        return 2
    mode = argv[0]
    if mode == "dump":
        raw, source, _ = clean_text.local_deny(os.environ)
        if not clean_text.deny_rule(raw, source):
            return 1
        fd = os.open(argv[1], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(raw)
        return 0
    deny = Deny(argv[1])
    if mode == "hits":
        at = [n for n, line in enumerate(_lines(argv[2] if len(argv) > 2 else "-"), 1) if deny.search(line)]
        print(len(at), ",".join(str(n) for n in at))
        return 0
    if mode == "files":
        for name in sys.stdin.read().split("\n"):
            if name and os.path.isfile(name) and any(deny.search(line) for line in _lines(name)):
                print(name)
        return 0
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
