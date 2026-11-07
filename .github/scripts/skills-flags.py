#!/usr/bin/env python3
"""skills-flags.py — check 2 of the help-text gates: the verbs and flags the skill files name exist in sala's help.

Usage: skills-flags.py HELP_TEXT SKILLS_DIR
  HELP_TEXT   the text `bash tests/help-snapshot.sh --generate` prints (the regenerated help, never the committed snapshot)
  SKILLS_DIR  the skills plugin's skills directory (every *.md under it is read)
Output: `FAIL <file>:<line> ...` for a verb or flag a skill names that the help does not have (exit 1);
        `WARN ...` for a flag in the help that no skill mentions (never fails); a last `skills-flags:` summary line.

The parser is deliberately simple and conservative, so that it cannot fail a good skill. A mention is `sala ...` or
`salamander ...` inside an inline code span or a fenced code block (prose is never read), where the word starts the
command (only a `$ ` prompt, VAR=value words, a path ending in `/`, or sudo/nohup/timeout N/env-like words before it). Its verb
is the next word if it is lowercase letters and hyphens; its flags are the `--long-flags` after it up to the first shell
separator (| ; & > < ) or backtick), with quoted strings dropped. A flag is checked against the text of THAT verb's
help (its lines in the top-level usage and its own usage output); `--help` is always accepted. Short flags are not read.
"""
import os
import re
import sys

SEP = re.compile(r"[|;&<>)`]|\$\(")
FLAG = re.compile(r"(?<![\w-])--[a-z][a-z0-9-]*")
ALLOWED_PREFIX = re.compile(
    r"^\s*(?:\$\s+)?(?:[A-Za-z_]\w*=\S*\s+)*(?:(?:timeout\s+\S+|sudo|nohup|setsid|time|exec|env|command)\s+)*(?:\S*/)?$"
)
MENTION = re.compile(r"(?<![\w-])(?:sala|salamander)(?=\s|$)")


def parse_help(path):
    """verb -> its help text (the top-level usage's lines for it, plus the output of its own help call)."""
    verbs, known = {}, []
    cur = None          # verb whose block the top-level lines belong to
    section = None      # the probe word of the section being read, or "" for the top-level text
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        if line.startswith("### "):
            m = re.match(r"### sala (--help|([a-z][a-z-]*)\b.*? --help) \(exit", line)
            if m and m.group(1) == "--help":
                section, cur = "", None
            elif m:
                section = m.group(2)
                verbs.setdefault(section, [])
            else:
                section = None   # the closing list of unprobed verbs: not help text
            continue
        if section is None:
            continue
        if section == "":
            m = re.match(r"  salamander ([a-z][a-z-]*)\b", line)
            if m:
                cur = m.group(1)
                if cur not in known:
                    known.append(cur)
                verbs.setdefault(cur, [])
            if cur:
                verbs[cur].append(line)
        else:
            verbs[section].append(line)
    return known, {v: "\n".join(t) for v, t in verbs.items()}


def mentions(text_lines):
    """yield (lineno, rest-of-command) for each sala command in a code context of a markdown file."""
    fence = False
    for no, line in enumerate(text_lines, 1):
        if re.match(r"\s*(```|~~~)", line):
            fence = not fence
            continue
        contexts = [line] if fence else re.findall(r"`([^`]+)`", line)
        for ctx in contexts:
            for m in MENTION.finditer(ctx):
                seg = max(ctx.rfind(c, 0, m.start()) for c in "|;&(")   # the segment of the command line it starts
                if seg >= 0:
                    seg += 1
                if not ALLOWED_PREFIX.match(ctx[max(seg, 0):m.start()]):
                    continue
                yield no, ctx[m.end():]


def main(argv):
    if len(argv) != 3:
        print(__doc__.strip().split("\n\n")[0], file=sys.stderr)
        return 2
    known, text = parse_help(argv[1])
    if not known:
        print("FAIL the help text %s names no verb (is it the output of help-snapshot.sh --generate?)" % argv[1])
        return 1
    alltext = "\n".join(text.values())
    seen = {v: set() for v in known}
    mentioned = set()
    fails = nfiles = nmentions = 0
    for root, _dirs, files in os.walk(argv[2], followlinks=True):
        for name in sorted(files):
            if not name.endswith(".md"):
                continue
            path = os.path.join(root, name)
            rel = os.path.relpath(path, argv[2])
            nfiles += 1
            with open(path, encoding="utf-8", errors="replace") as fh:
                lines = fh.read().split("\n")
            for no, rest in mentions(lines):
                rest = re.sub(r'"[^"]*"|\'[^\']*\'', " ", rest)
                cut = SEP.search(rest)
                if cut:
                    rest = rest[:cut.start()]
                words = rest.split()
                verb = None
                if words and re.fullmatch(r"[a-z][a-z-]*", words[0]):
                    verb = words[0]
                    if verb not in known:
                        print("FAIL %s:%d `sala %s`: no such verb in sala's help" % (rel, no, verb))
                        fails += 1
                        continue
                nmentions += 1
                if verb:
                    mentioned.add(verb)
                haystack = text.get(verb, "") if verb else alltext
                for flag in FLAG.findall(rest):
                    if verb:
                        seen[verb].add(flag)
                    if flag == "--help" or flag in haystack:
                        continue
                    print("FAIL %s:%d `sala %s%s`: help for %s has no %s"
                          % (rel, no, (verb + " ") if verb else "", flag, ("'" + verb + "'") if verb else "sala", flag))
                    fails += 1
    unmentioned = []
    for verb in known:
        flags = sorted(set(FLAG.findall(text.get(verb, ""))) - {"--help"})
        if verb not in mentioned:
            unmentioned.append(verb)
            continue
        missing = [f for f in flags if f not in seen[verb]]
        if missing:
            print("WARN sala %s: in the help, named by no skill: %s" % (verb, " ".join(missing)))
    if unmentioned:
        print("WARN verbs in the help that no skill names: %s" % " ".join(unmentioned))
    print("skills-flags: %d skill file(s), %d sala mention(s), %d FAIL" % (nfiles, nmentions, fails))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
