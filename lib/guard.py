"""lib/guard.py — the decision behind `salamander hook pre-tool`.

A PreToolUse hook on Bash: it denies a command, typed by a session outside sala, that would relaunch or update the fleet:
  reboot      reboot · shutdown -r / --reboot · systemctl reboot|kexec|soft-reboot · systemctl start|isolate reboot.target
              (kexec.target, soft-reboot.target) · init 6 / telinit 6
  update      claude update|upgrade|install (any path to the launcher, or a versions/<v> binary) · npm/pnpm/yarn/bun
              installing @anthropic-ai/claude-code · the native installer (claude.ai/install.sh) fed to a shell
  tmux        tmux kill-server|kill-session|kill-pane|kill-window (killp, killw, unique prefixes, \\; chains) on the
              fleet's tmux server — the default one, or SALA_TMUX_SOCKET
  tmuxwin     tmux new-window · split-window · respawn-pane · respawn-window · join-pane · move-pane · break-pane ·
              swap-pane · swap-window · move-window · link-window · rename-session (their aliases and unambiguous
              prefixes), and new-session -t, whose target (-t, or -s for the commands that take a source) is a session
              other than the caller's own on the fleet's tmux server: what is placed there runs as that session
              review). A target with no colon is also looked up as `<target>:` (`=name`, a shadowing window name); a word
              that ends in ';' ends a tmux command; a TMUX_PANE assignment, env -u TMUX_PANE or env -i in front of one is
              denied. No -t, a target in the caller's own session, an unknown target, and a private server pass. Not read
              (known limits): if-shell, run-shell, pipe-pane, source-file, bind-key carrying a placement, and -t "$VAR".
  kill        kill of a literal pid that is a claude process (/proc/<pid>/comm or exe), kill -1 (everything), kill of a
              process group (-PGID) holding one · pkill/killall whose pattern literally names claude
              EXCEPT (a guard that blocks a session's own cleanup works against it): `kill <pid>` of the claude
              of a throwaway the calling session started itself: the pid sits in a tmux pane of session S on the caller's
              server, S is not the caller or the master, and the registry has one live row S with no project, role or side
              and spawned_by = the caller (`spawn` writes it). The caller is the tmux session of TMUX_PANE; none,
              or any read failing, and the stop is a hit as before.
Exempt: the sala master's own pane (hook.sh passes SALA_MASTER; TMUX_PANE's tmux session is compared, as master_guard
does; nothing is exempt once SALA_MASTER is unset) · sala's own verbs (`sala …`, `salamander …`: the command word is
sala, so no rule sees its arguments) · a private tmux server (-L <name> / -S <path> / a $TMUX that is not the fleet's).
The deny names the queue's verb for the command (`sala op <verb> … --from NAME --words "<the owner's words>"`, lib/op.sh;
Thu Oct 15th 2026): a session queues the operation, sala's watch runs it. A reboot is the exception: it is not
queued (SALA_OP_REBOOT is off by default and unsupported until a confirmation path is built), so its deny says the owner runs
`sala reboot --go` directly and the session shows `sala reboot --status` and waits for the word. The logic is untouched.

TIGHT BY DESIGN: anything that cannot be read off the command passes — a pid in a variable, `$(pgrep …)`, `… | xargs kill`,
`ssh <host> …` (not looked into), a heredoc body fed to a shell. It never runs another command to decide (the only
subprocesses are tmux: `display` for the caller, after a match, and `list-panes` to place a claude pid in a session). `bash -c` / `sh -c` strings are checked as commands.
FAIL OPEN: any exception → nothing printed → the call proceeds.

Input: the PreToolUse hook JSON on stdin (tool_input.command). Argument 1: the master's tmux session name (may be empty).
Output: nothing (allow), or the documented deny object:
  {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "…"}}
"""
import json
import os
import re
import sys

OWNER = os.environ.get("SALA_OWNER_NAME") or "the owner"   # what the denies call the person running this machine (config SALA_OWNER_NAME; the hook exports it)
SHELLS = {"sh", "bash", "dash", "zsh", "ksh"}
KEYWORDS = {"if", "then", "elif", "else", "while", "until", "do", "!", "{", "}", "time", "fi", "done", "esac", "coproc"}
SKIP_FIRST = {"for", "case", "select", "function", "[[", "[", "test", "echo", "printf", ":", "true", "false"}
# wrappers: name → (options that take an argument, number of positionals to skip after the options)
WRAPPERS = {
    "sudo": ({"-u", "-g", "-h", "-p", "-C", "-D", "-r", "-t", "-U", "-T", "-R", "--user", "--group", "--host",
              "--prompt", "--close-from", "--chdir", "--role", "--type", "--other-user", "--command-timeout", "--chroot"}, 0),
    "doas": ({"-u", "-C"}, 0),
    "env": ({"-u", "--unset", "-C", "--chdir", "-S", "--split-string"}, 0),
    "nohup": (set(), 0),
    "setsid": (set(), 0),
    "nice": ({"-n", "--adjustment"}, 0),
    "ionice": ({"-c", "-n", "-t", "--class", "--classdata"}, 0),
    "timeout": ({"-s", "--signal", "-k", "--kill-after"}, 1),
    "stdbuf": ({"-i", "-o", "-e", "--input", "--output", "--error"}, 0),
    "command": (set(), 0),
    "exec": ({"-a"}, 0),
    "builtin": (set(), 0),
    "time": (set(), 0),
}
TMUX_KILLS = ("kill-server", "kill-session", "kill-pane", "kill-window")
TMUX_ALIASES = {"killp": "kill-pane", "killw": "kill-window"}
TMUX_ARG_OPTS = set("cfLST")
INSTALLER = re.compile(r"claude\.ai/install\.(sh|ps1|cmd)")
NAME_ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=")
PH = re.compile(r"\x00(\d+)\x00")   # a substitution's placeholder inside a word


class Word:
    __slots__ = ("text", "dyn", "subs")

    def __init__(self):
        self.text, self.dyn, self.subs = [], False, []

    def done(self):
        self.text = "".join(self.text)
        return self


def _skip_quoted(s, i, q):
    """i at an opening quote q → index after its closing quote (backslashes count inside double quotes)."""
    i += 1
    while i < len(s):
        c = s[i]
        if q == '"' and c == "\\":
            i += 2
            continue
        if c == q:
            return i + 1
        i += 1
    return i


def _balanced(s, i, open_="(", close=")"):
    """i just past an opening bracket → (body, index after the matching close), respecting quotes."""
    depth, j = 1, i
    while j < len(s):
        c = s[j]
        if c == "\\":
            j += 2
            continue
        if c in "'\"":
            j = _skip_quoted(s, j, c)
            continue
        if c == open_:
            depth += 1
        elif c == close:
            depth -= 1
            if depth == 0:
                return s[i:j], j + 1
        j += 1
    return s[i:], len(s)


def lex(s):
    """A small bash tokenizer → (tokens, substitution bodies). Tokens: ("w", Word) · ("op", text) · ("redir", takes_target).
    Quotes are removed from words; $( ), ` `, <( ) and >( ) bodies become placeholders (their text kept for a recursive
    check); heredoc bodies and comments are dropped; any other $-expansion marks the word dynamic."""
    toks, subs, heredocs = [], [], []
    i, n, cur = 0, len(s), None

    def word():
        nonlocal cur
        if cur is None:
            cur = Word()
        return cur

    def flush():
        nonlocal cur
        if cur is not None:
            toks.append(("w", cur.done()))
            cur = None

    def sub(body):
        w = word()
        w.subs.append(len(subs))
        w.dyn = True
        w.text.append("\x00%d\x00" % len(subs))
        subs.append(body)

    while i < n:
        c = s[i]
        if c == "\n":
            flush()
            toks.append(("op", "\n"))
            i += 1
            for delim, strip in heredocs:   # the bodies: data, never commands
                while i < n:
                    e = s.find("\n", i)
                    line = s[i:] if e < 0 else s[i:e]
                    i = n if e < 0 else e + 1
                    if (line.lstrip("\t") if strip else line) == delim:
                        break
            heredocs = []
        elif c in " \t\r":
            flush()
            i += 1
        elif c == "\\":
            if i + 1 < n and s[i + 1] == "\n":
                i += 2
            else:
                if i + 1 < n:
                    word().text.append(s[i + 1])
                i += 2
        elif c == "#" and cur is None:
            e = s.find("\n", i)
            i = n if e < 0 else e
        elif c == "'":
            j = _skip_quoted(s, i, "'")
            word().text.append(s[i + 1:j - 1])
            i = j
        elif c == '"':
            w = word()
            i += 1
            while i < n and s[i] != '"':
                d = s[i]
                if d == "\\" and i + 1 < n:
                    w.text.append(s[i + 1] if s[i + 1] in '$`"\\\n' else d + s[i + 1])
                    i += 2
                elif d == "$" and s.startswith("$((", i):
                    body, i = _balanced(s, i + 3)
                    w.dyn = True
                    w.text.append("$((" + body)
                elif d == "$" and s.startswith("$(", i):
                    body, i = _balanced(s, i + 2)
                    sub(body)
                elif d == "`":
                    e = s.find("`", i + 1)
                    e = n if e < 0 else e
                    sub(s[i + 1:e])
                    i = e + 1
                elif d == "$" and i + 1 < n and (s[i + 1] in "{_@*#?$!-" or s[i + 1].isalnum()):
                    w.dyn = True
                    w.text.append(d)
                    i += 1
                else:
                    w.text.append(d)
                    i += 1
            i += 1
        elif c == "`":
            e = s.find("`", i + 1)
            e = n if e < 0 else e
            sub(s[i + 1:e])
            i = e + 1
        elif c == "$":
            if s.startswith("$((", i):
                body, i = _balanced(s, i + 3)
                word().dyn = True
                word().text.append("$((" + body)
            elif s.startswith("$(", i):
                body, i = _balanced(s, i + 2)
                sub(body)
            elif s.startswith("$'", i):
                j = i + 2
                while j < n and s[j] != "'":
                    j += 2 if s[j] == "\\" else 1
                word().text.append(s[i + 2:j])
                i = j + 1
            elif s.startswith("${", i):
                body, i = _balanced(s, i + 2, "{", "}")
                word().dyn = True
                word().text.append("${" + body + "}")
            elif i + 1 < n and (s[i + 1] in "_@*#?$!-" or s[i + 1].isalnum()):
                word().dyn = True
                word().text.append("$")
                i += 1
            else:
                word().text.append("$")
                i += 1
        elif c in "<>" and i + 1 < n and s[i + 1] == "(":
            body, i = _balanced(s, i + 2)
            sub(body)
        elif c in "<>":
            if cur is not None and not cur.dyn and "".join(cur.text).isdigit():
                cur = None   # an fd number (2>&1): not a word
            else:
                flush()
            for op in ("<<<", "<<-", "<<", "<>", "<&", ">>", ">&", ">|", "<", ">"):
                if s.startswith(op, i):
                    break
            i += len(op)
            if op in ("<<", "<<-"):
                while i < n and s[i] in " \t":
                    i += 1
                j, delim = i, []
                while j < n and s[j] not in " \t\n;&|<>()":
                    if s[j] in "'\"":
                        k = _skip_quoted(s, j, s[j])
                        delim.append(s[j + 1:k - 1])
                        j = k
                    else:
                        if s[j] != "\\":
                            delim.append(s[j])
                        j += 1
                heredocs.append(("".join(delim), op == "<<-"))
                i = j
                toks.append(("redir", False))
            else:
                toks.append(("redir", True))
        elif c == "&" and s.startswith("&>", i):
            flush()
            i += 3 if s.startswith("&>>", i) else 2
            toks.append(("redir", True))
        elif c in ";&|()":
            flush()
            op = s[i:i + 2] if s[i:i + 2] in (";;", "&&", "||", "|&", ";&") else c
            toks.append(("op", op))
            i += len(op)
        else:
            word().text.append(c)
            i += 1
    flush()
    return toks, subs


def pipelines(toks):
    """tokens → list of pipelines, each a list of simple commands (lists of Words; redirect targets dropped)."""
    out, pl, words, skip = [], [], [], False
    for t in toks:
        if t[0] == "w":
            if skip:
                skip = False
            else:
                words.append(t[1])
        elif t[0] == "redir":
            skip = t[1]
        elif t[1] in ("|", "|&"):
            pl.append(words)
            words = []
        else:
            pl.append(words)
            out.append(pl)
            pl, words = [], []
    pl.append(words)
    out.append(pl)
    return [[c for c in p if c] for p in out]


def base(w):
    return os.path.basename(w.text) if not w.dyn else ""


def unwrap(argv):
    """Drop leading keywords, assignments and wrappers (sudo, env, nohup, timeout …) → (argv, extra command strings to
    check: env -S)."""
    extra = []
    while argv:
        t = argv[0].text if not argv[0].dyn else None
        if t in KEYWORDS or (t is not None and NAME_ASSIGN.match(t)):
            argv = argv[1:]
            continue
        b = base(argv[0])
        if b not in WRAPPERS:
            break
        with_arg, npos = WRAPPERS[b]
        j = 1
        while j < len(argv):
            a = argv[j].text
            if a == "--":
                j += 1
                break
            if b == "env" and NAME_ASSIGN.match(a):
                j += 1
                continue
            if not a.startswith("-") or a == "-":
                break
            if b == "command" and a in ("-v", "-V"):
                return [], extra   # a lookup, not a run
            if b == "env" and a in ("-S", "--split-string") and j + 1 < len(argv):
                extra.append(argv[j + 1].text)
            opt = a.split("=", 1)[0]
            j += 2 if (opt in with_arg and "=" not in a) else 1
        j += npos
        argv = argv[j:]
    return argv, extra


def is_claude_path(p):
    return os.path.basename(p) == "claude" or "/claude/versions/" in p


def is_claude_pid(pid):
    try:
        with open("/proc/%d/comm" % pid) as fh:
            if fh.read().strip() == "claude":
                return True
    except OSError:
        pass
    try:
        return is_claude_path(os.readlink("/proc/%d/exe" % pid))
    except OSError:
        return False


def group_has_claude(pgid):
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        try:
            with open("/proc/%s/stat" % d) as fh:
                st = fh.read()
            if int(st[st.rindex(")") + 2:].split()[2]) == pgid and is_claude_pid(int(d)):
                return True
        except (OSError, ValueError, IndexError):
            continue
    return False


def names_claude(pattern):
    """a pkill/killall pattern that literally names claude — not merely a path under ~/.claude, /tmp/claude-<uid>, or
    the claude.ai domain"""
    p = re.sub(r"\.claude/|/claude-\d+|claude\.ai", "", pattern, flags=re.I)
    return re.search(r"claude", p, re.I) is not None


def fleet_socket():
    s = os.environ.get("SALA_TMUX_SOCKET")
    return os.path.realpath(s) if s else os.path.realpath(
        os.path.join(os.environ.get("TMUX_TMPDIR") or "/tmp", "tmux-%d" % os.getuid(), "default"))


def tmux_rule(argv, depth):
    """tmux … kill-* on the fleet's server → the matched text; a private server (-L/-S/$TMUX) passes"""
    sock, j = None, 1
    while j < len(argv):
        a = argv[j].text
        if a == "--":
            j += 1
            break
        if not a.startswith("-") or a == "-":
            break
        k = 1
        while k < len(a):
            if a[k] in TMUX_ARG_OPTS:
                val = a[k + 1:]
                if not val and j + 1 < len(argv):
                    j += 1
                    val = argv[j].text if not argv[j].dyn else None
                if val is None:
                    return None   # a socket from a variable: cannot tell
                if a[k] == "L":
                    sock = os.path.join(os.environ.get("TMUX_TMPDIR") or "/tmp", "tmux-%d" % os.getuid(), val)
                elif a[k] == "S":
                    sock = val
                elif a[k] == "c":
                    hit = check(val, depth + 1)   # tmux -c runs its argument as a shell command
                    if hit:
                        return hit
                break
            k += 1
        j += 1
    if sock is None:
        env = os.environ.get("TMUX", "")
        sock = env.split(",")[0] if env else os.path.join(os.environ.get("TMUX_TMPDIR") or "/tmp", "tmux-%d" % os.getuid(), "default")
    if os.path.realpath(sock) != fleet_socket():
        return None
    rest, cmds, c = argv[j:], [], []
    for w in rest:
        t = w.text
        if w.dyn or not t.endswith(";") or t.endswith("\\;"):
            c.append(w)
            continue
        # tmux ends a command at a word that ends in ';' (an escaped "\;" stays literal): `new-window -t owner:\; new-window -t x:`
        # reaches it as the word `owner:;`
        if t[:-1]:
            nw = Word()
            nw.text, nw.dyn, nw.subs = t[:-1], False, []
            c.append(nw)
        cmds.append(c)
        c = []
    cmds.append(c)
    for c in cmds:
        if not c or c[0].dyn:
            continue
        name = c[0].text
        full = TMUX_ALIASES.get(name)
        if not full and name.startswith("kill-"):
            m = [k for k in ("kill-server", "kill-session", "kill-pane", "kill-window") if k.startswith(name)]
            full = m[0] if len(m) == 1 or name in m else None
        if full in TMUX_KILLS:
            return ("tmux", "tmux " + full)
        hit = placement_rule(c)
        if hit:
            return hit
    return None


# tmux commands that put a process into a session's panes (a window placed into another session runs as that
# session, so it borrows that session's identity). name → (full name, options that take an argument, options that name a target)
TMUX_PLACE = {}
TMUX_PLACE_FULL = []
# (full name, alias, options that take an argument in tmux 3.6's parser, options that name a target). The option strings are read off
# `tmux list-commands` (3.6) plus the hidden -p (a percentage) that split-window, join-pane and move-pane still parse.
for _full, _alias, _opts, _tgt in (
    ("new-window", "neww", "cenFt", "t"),
    ("split-window", "splitw", "celFpt", "t"),
    ("respawn-pane", "respawnp", "cet", "t"),
    ("respawn-window", "respawnw", "cet", "t"),
    ("join-pane", "joinp", "lpst", "st"),
    ("move-pane", "movep", "lpst", "st"),
    ("break-pane", "breakp", "Fnst", "st"),
    ("swap-pane", "swapp", "st", "st"),
    ("swap-window", "swapw", "st", "st"),
    ("move-window", "movew", "st", "st"),
    ("link-window", "linkw", "st", "st"),
    ("rename-session", "rename", "t", "t"),
    ("new-session", "new", "cefFnstxy", "t"),   # -t groups with a session; without -t it is unrelated
):
    TMUX_PLACE[_full] = TMUX_PLACE[_alias] = (_full, _opts, _tgt)
    TMUX_PLACE_FULL.append(_full)

# a command that sets or clears TMUX_PANE (or the whole environment) in front of a tmux command moves what "the current session" means
# for it: tmux takes the default target from TMUX_PANE
PANE_TAINT_RE = re.compile(r"TMUX_PANE\s*\+?=|-u\s*TMUX_PANE|--unset[=\s]+TMUX_PANE|\bunset\s+[^;&|]*TMUX_PANE|\benv\s+(?:-\w*i\w*|--ignore-environment)\b")
PANE_TAINT = [False]


def place_entries(name):
    """the placement commands a tmux command word can mean: an exact name or alias, else every placement command it is a prefix of
    (tmux accepts an unambiguous prefix: `new-win`, `split-w`; treating an ambiguous one as each of them only errs towards a deny)"""
    ent = TMUX_PLACE.get(name)
    if ent:
        return [ent]
    if len(name) < 2:
        return []
    return [TMUX_PLACE[f] for f in TMUX_PLACE_FULL if f.startswith(name)]


def target_sessions(t):
    """the sessions a tmux target can name, on the caller's server: [] for the caller's own (no session part) or when it cannot be told.
    A target with no colon and no %@$ sigil may be a window or pane name in the caller's own session that shadows a session of that
    name, or `=name` (which `display -t` does not resolve as a session), so `<t>:` is looked up as a session too."""
    if not t:
        return []
    if t[0] in "%@$":
        qs = [t]
    elif ":" in t:
        head = t.split(":", 1)[0]
        if not head:
            return []
        qs = [head + ":"]
    else:
        qs = [t, t + ":"]
    names = []
    for q in qs:
        out = tmux_out(["display", "-p", "-t", q, "#{session_name}"]).strip()
        if out:
            names.append(out)
    return names


def placement_rule(c):
    """one tmux command (words) that puts a window, pane or session group into a session other than the caller's → hit, else None"""
    ents = place_entries(c[0].text)
    for ent in ents:
        hit = placement_one(c, ent)
        if hit:
            return hit
    return None


def placement_one(c, ent):
    full, argopts, tgtopts = ent
    if PANE_TAINT[0]:
        return ("tmuxwin", "tmux %s with TMUX_PANE set, unset or the environment cleared in front of it" % full)
    targets, j = [], 1
    while j < len(c):
        a = c[j]
        if a.dyn or not a.text.startswith("-") or a.text == "-":
            break   # the first positional is the shell command (or a name): options end there
        if a.text == "--":
            break
        k = 1
        while k < len(a.text):
            o = a.text[k]
            if o in argopts:
                val = a.text[k + 1:]
                if not val and j + 1 < len(c):
                    j += 1
                    val = c[j].text if not c[j].dyn else None
                if o in tgtopts and val is not None:
                    targets.append((o, val))
                break
            k += 1
        j += 1
    me = caller_session()
    for o, t in targets:
        for s in target_sessions(t):
            if s != me:
                return ("tmuxwin", "tmux %s -%s %s" % (full, o, t))
    return None


OWN_OK = None   # set by main(): pid → True when it is the claude of a throwaway the calling session started itself


def kill_rule(args):
    if any(a.text in ("-l", "-L", "--list", "--table") for a in args if not a.dyn):
        return None
    j = 0
    if args and not args[0].dyn:
        a = args[0].text
        if a in ("-s", "-n", "--signal"):
            j = 2
        elif a.startswith("-") and a != "--":
            j = 1
    if j < len(args) and args[j].text == "--":
        j += 1
    for w in args[j:]:
        if w.dyn or not re.fullmatch(r"-?\d+", w.text):
            continue   # %job, a variable, $(pgrep …): passes
        pid = int(w.text)
        if pid == -1:
            return ("kill", "kill -1")
        if pid < -1 and group_has_claude(-pid):
            return ("kill", "process group %d" % -pid)
        if pid > 0 and is_claude_pid(pid):
            if OWN_OK is not None and OWN_OK(pid):
                continue   # a throwaway the caller started itself: not a hit
            return ("kill", "pid %d (claude)" % pid)
    return None


def pattern_rule(b, args):
    """pkill / killall: a pattern (any non-option argument) that literally names claude"""
    for w in args:
        if not w.dyn and not w.text.startswith("-") and names_claude(w.text):
            return ("kill", "%s %s" % (b, w.text))
    return None


def first_arg(args):
    for w in args:
        if w.dyn:
            return None
        if not w.text.startswith("-"):
            return w.text
    return None


def simple(argv, pl, idx, subs, depth):
    argv, extra = unwrap(argv)
    for x in extra:
        hit = check(x, depth + 1)
        if hit:
            return hit
    if not argv or argv[0].dyn:
        return None
    w0 = argv[0].text
    b = os.path.basename(w0)
    if b in SKIP_FIRST or b in ("sala", "salamander") or b.startswith("sala-"):
        return None   # sala's own verbs; echo/printf/test words are data
    args = argv[1:]
    if b == "reboot":
        return ("reboot", "reboot")
    if b == "shutdown":
        for w in args:
            t = w.text
            if t == "--reboot" or (t.startswith("-") and not t.startswith("--") and "r" in t[1:]):
                return ("reboot", "shutdown " + t)
        return None
    if b in ("init", "telinit") and [w.text for w in args] == ["6"]:
        return ("reboot", b + " 6")
    if b == "systemctl":
        pos = [w.text for w in args if not w.text.startswith("-")]
        if pos and pos[0] in ("reboot", "kexec", "soft-reboot"):
            return ("reboot", "systemctl " + pos[0])
        if pos and pos[0] in ("start", "isolate") and any(p in ("reboot.target", "kexec.target", "soft-reboot.target") for p in pos[1:]):
            return ("reboot", "systemctl %s %s" % (pos[0], pos[1]))
        return None
    if is_claude_path(w0):
        verb = first_arg(args)
        if verb in ("update", "upgrade", "install"):
            return ("update", "claude " + verb)
        return None
    if b in ("npm", "pnpm", "yarn", "bun"):
        ts = [w.text for w in args]
        if any(re.match(r"^@anthropic-ai/claude-code(@|$)", t) for t in ts) and \
                any(t in ("install", "i", "add", "update", "up", "upgrade", "global") for t in ts):
            return ("update", "%s … @anthropic-ai/claude-code" % b)
        return None
    if b in ("curl", "wget") and any(INSTALLER.search(w.text) for w in args):
        if idx + 1 < len(pl):
            nxt, _ = unwrap(pl[idx + 1])
            if nxt and base(nxt[0]) in SHELLS:
                return ("update", "the native installer piped to a shell")
        return None
    if b in SHELLS:
        for w in args:
            if any(INSTALLER.search(subs[k]) for k in w.subs):
                return ("update", "the native installer run by a shell")
        for k, w in enumerate(args):
            t = w.text
            if not w.dyn and t.startswith("-") and not t.startswith("--") and "c" in t[1:]:
                rest = [x for x in args[k + 1:] if not x.text.startswith("-")]
                if rest and not rest[0].dyn:
                    return check(rest[0].text, depth + 1)
                return None
        return None
    if b == "tmux":
        return tmux_rule(argv, depth)
    if b == "kill":
        return kill_rule(args)
    if b in ("pkill", "killall"):
        return pattern_rule(b, args)
    return None


def check(cmd, depth=0):
    """→ (kind, what) for the first rule a command hits, else None"""
    if depth > 4 or not cmd:
        return None
    if depth == 0:
        PANE_TAINT[0] = PANE_TAINT_RE.search(cmd) is not None
    toks, subs = lex(cmd)
    for body in subs:   # a substitution's body runs too
        hit = check(body, depth + 1)
        if hit:
            return hit
    for pl in pipelines(toks):
        for idx, argv in enumerate(pl):
            hit = simple(argv, pl, idx, subs, depth)
            if hit:
                return hit
    return None


EFFECT = {
    "reboot": "reboots the box, and every pane on it",
    "update": "updates the Claude Code CLI, which the fleet is relaunched onto",
    "tmux": "kills Claude panes on the fleet's tmux server",
    "kill": "stops a Claude session's process (kill -1: every process)",
    "tmuxwin": "puts a window, pane or session group into another session's tmux, where it runs as that session",
}
VERB = {   # the queue's verb for each kind (lib/op.sh, THE VERBS); a reboot has none: it is not queued (NOT_QUEUED)
    "update": "update",
    "tmux": "retire <session>",
    "kill": "retire <session> (or revive --only <session> --force, to relaunch it)",
}
NOT_QUEUED = {   # kinds the queue does not take (lib/op.sh: SALA_OP_REBOOT off by default, unsupported until a confirmation path is built)
    "reboot": "A reboot is not queued: %s runs `sala reboot --go` in the web UI's Shell. Show `sala reboot --status` and wait for the word." % OWNER,
    "tmuxwin": "Nothing queues it. Run the command in your own session (`-t <you>:`), in a throwaway you start with a bare `sala spawn NAME` (it is yours to retire), or on a private test server (`tmux -L <name> -f /dev/null`).",
}


_CALLER = []   # one tmux call per run


def caller_session():
    if _CALLER:
        return _CALLER[0]
    pane = os.environ.get("TMUX_PANE")
    out = ""
    if pane:
        import subprocess
        try:
            r = subprocess.run(["tmux", "display", "-p", "-t", pane, "#{session_name}"], capture_output=True, text=True, timeout=3)
            out = r.stdout.strip() if r.returncode == 0 else ""
        except Exception:
            out = ""
    _CALLER.append(out)
    return out


def tmux_out(args):
    import subprocess
    r = subprocess.run(["tmux"] + args, capture_output=True, text=True, timeout=3)
    return r.stdout if r.returncode == 0 else ""


def session_of_pid(pid):
    """the tmux session whose pane holds pid (the pid or one of its ancestors is the pane's process), on the caller's server"""
    panes = {}
    for ln in tmux_out(["list-panes", "-a", "-F", "#{pane_pid} #{session_name}"]).splitlines():
        a, _, name = ln.partition(" ")
        if a.isdigit() and name:
            panes[int(a)] = name
    for _ in range(64):
        if pid in panes:
            return panes[pid]
        with open("/proc/%d/stat" % pid) as fh:
            st = fh.read()
        pid = int(st[st.rindex(")") + 2:].split()[1])
        if pid <= 1:
            break
    return None


def registry_file():
    f = os.environ.get("SALA_SESSIONS_FILE")
    if f:
        return f
    side = os.environ.get("SALA_SIDECAR")
    if side:
        return os.path.join(os.path.dirname(side), "sessions.json")
    return os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state"),
                        "salamander", "sessions.json")


def own_throwaway(name, me):
    """the row id when the registry has exactly one live row called name, with no project, no role and no side session,
    started by me (spawned_by, written by `spawn`); else None"""
    with open(registry_file(), encoding="utf-8") as fh:
        d = json.load(fh)
    rows = [r for r in d["sessions"].values() if r.get("state") == "live" and r.get("name") == name]
    if len(rows) != 1:
        return None
    r = rows[0]
    if (r.get("project") or r.get("role") or r.get("side")) or not me or r.get("spawned_by") != me:
        return None
    return r.get("id") or None


def process_session_id(pid):
    """SALA_SESSION_ID in the environment of pid (`sala spawn` gives it to the throwaway's pane and claude: the registry row's
    id); None when absent or unreadable"""
    with open("/proc/%d/environ" % pid, "rb") as fh:
        for kv in fh.read().split(b"\0"):
            if kv.startswith(b"SALA_SESSION_ID="):
                return kv[len(b"SALA_SESSION_ID="):].decode("utf-8", "replace") or None
    return None


def make_own_ok(master):
    """The allowance for a session's own cleanup, since a guard that blocks it works against the session: `kill <pid>` of the claude of a throwaway
    the calling session started itself is not a hit. The caller is the tmux session of TMUX_PANE (the identity the master
    check and `sala op` use); no caller, no allowance. The pid must also carry the row's id as SALA_SESSION_ID (a victim renamed to the name is not the throwaway). Any failure reading the pane, the registry or the process → not allowed."""
    def ok(pid):
        try:
            me = caller_session()
            if not me:
                return False
            s = session_of_pid(pid)
            if not s or s == me or s == master:
                return False
            rid = own_throwaway(s, me)
            # the pid is bound to the row by the process, not by the tmux session name alone: a session renamed to a dead
            # throwaway's name carries another SALA_SESSION_ID (a review finding)
            return bool(rid) and process_session_id(pid) == rid
        except Exception:
            return False
    return ok


def main():
    global OWN_OK
    try:
        d = json.loads(sys.stdin.read())
        if not isinstance(d, dict) or d.get("tool_name", "Bash") != "Bash":
            return
        ti = d.get("tool_input")
        cmd = ti.get("command") if isinstance(ti, dict) else None
        if not isinstance(cmd, str):
            return
        master = sys.argv[1] if len(sys.argv) > 1 else ""
        OWN_OK = make_own_ok(master)   # asks tmux only when a claude pid is named
        hit = check(cmd)
        if not hit:
            return
        me = caller_session()
        if master and me == master:
            return   # the master runs fleet operations itself
        kind, what = hit
        if kind in NOT_QUEUED:
            reason = "sala guard: `%s` %s, and a session never runs that itself. %s" % (what, EFFECT[kind], NOT_QUEUED[kind])
        else:
            # the queue's verb for it (Thu Oct 15th 2026): a session queues the operation, sala's watch runs it
            fix = 'sala op %s --from %s --words "<%s\'s words>"' % (VERB[kind], me or "<you>", OWNER)
            reason = "sala guard: `%s` %s, and a session never runs that itself; sala's operation queue does. Queue it: %s (the plan is shown first; the recycle procedure does exactly that)." % (
                what, EFFECT[kind], fix)
        if kind == "kill":
            reason += " One stop is yours without a queue: `kill <pid>` of the claude of a throwaway you started yourself (a bare `spawn` from this session). Every other stop (a project or role agent, a side session, another session's throwaway, your own session, a name with pkill or killall, kill -1, a process group) goes through the queue."
        if kind == "tmux":
            reason += " A test tmux belongs on a private server: tmux -L <name> -f /dev/null."
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                                 "permissionDecisionReason": reason}}, ensure_ascii=False))
    except Exception:
        return   # fail open


if __name__ == "__main__":
    main()
