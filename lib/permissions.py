#!/usr/bin/env python3
"""lib/permissions.py — the PermissionRequest hook of sala's panes: approve a permission prompt at once, and leave the dialog alone
for the few cases that must stay a person's.

  permissions.py        reads the PermissionRequest hook input on stdin (lib/hook.sh, `salamander hook permission-request`).
                        APPROVE: prints {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}.
                        LEAVE:   prints nothing. The CLI then shows its normal dialog, and sala's instant alert D (`hook notify`,
                        docs/stuck-question-recovery.md) posts it about 6 s later. A PermissionRequest hook can only allow or deny,
                        never defer, so "leave" is silence, never a deny.
                        Exit 0 on every path, whatever happens (an error is a leave). One line per decision goes to
                        $SALA_PERMISSION_LOG (~/.claude/salamander-permission.log): allowed|left, tool, why, session, input (80 chars, masked).
  SALA_PERMISSION_APPROVE=off|0|no|false   leaves every prompt (the hook still logs it).

Auto-approve comes first and the dialog is the fallback. Everything not in the table below is approved.
This is a net for the prompts that mean something to a person, not a sandbox: a command text is matched as text, so a path written
by a shell trick (a variable, a glob, an encoded string) can slip through. docs/permission-hook.md says what each rule is for.
"""
import json, os, re, shlex, sys, time

# ══ THE TABLE: what is never approved ═══════════════════════════════════════════════════════════════════════════════════════════
# Change a rule here and nowhere else. Each regex is matched, case-insensitively, against the text a call carries (see SCANNED below),
# after `~`, $HOME, `/./` and `x/../` are resolved (paths also by realpath). A match leaves the dialog. First match names the reason.

# 1. A tool that asks a person a question: the answer is the owner's, and approving the call would answer it for them.
LEAVE_TOOLS = re.compile(r"""(?ix)
    ^(AskUserQuestion|ExitPlanMode|EnterPlanMode)$           # the CLI's own question and plan-approval tools
  | ask_?user | question_?user | elicit | request_?(input|approval) | human_?(input|approval)   # any other tool that asks (an MCP server's too)
  | ^mcp__.*__confirm$                                       # stackshot's confirm records a person's yes
""")

# 2. The permission and instruction surface: what decides what a session may do, or what it is told. A session that could edit these
#    through an auto-approved call could grant itself anything, so each stays a person's decision.
SURFACE = [
    (r"\.claude/settings[\w.-]*\.json",                  "claude settings"),         # ~/.claude/settings.json, <repo>/.claude/settings.local.json, a backup
    (r"(?<![\w-])\.claude\.json(?![\w-])",               "claude.json"),             # ~/.claude.json (MCP servers, trust)
    (r"(?<![\w.-])settings(\.local)?\.json(?![\w-])",    "settings json"),           # the bare name, for `cd ~/.claude && … settings.json` and a relative path
    (r"CLAUDE(\.local)?\.md",                            "CLAUDE.md"),               # the instructions a session loads
    (r"(?<![\w-])\.mcp\.json(?![\w-])",                  ".mcp.json"),               # a project's MCP servers
    (r"managed-settings|/etc/claude-code",               "managed settings"),        # the admin layer
    (r"(?<![\w.-])hooks?/",                              "hooks directory"),         # ~/.claude/hooks/, <repo>/hooks/, .git/hooks/ (tested on the path with a / added)
]

# 3. Credentials: a call that reads or writes them is the owner's to see.
CREDENTIALS = [
    (r"(?<![\w-])\.(ssh|aws|gnupg)(?![\w-])",            "ssh/aws/gnupg"),           # keys and cloud logins
    (r"\.env(\.[\w.-]*)?(?![\w-])",                      ".env file"),               # .env, .env.local, prod.env (a process.env mention in a command too: the cost of a net)
    (r"(gbrain|stackshot)[\w./-]*(token|secret|credential|api[-_]?key|\.env)", "gbrain/stackshot credentials"),
    (r"(?<![\w-])id_(rsa|dsa|ecdsa|ed25519)",            "private key"),
    (r"[\w-]\.(pem|p12|pfx|key)(?![\w.-])",              "key file"),
    (r"private[-_ ]?key",                                "private key"),
    (r"(token|secret|credential|passw(or)?d)s?[\w.-]*\.(json|txt|key|pem|env|ya?ml|toml|ini|conf|cfg|token|secret|dat|db)(?![\w-])", "secret file name"),
    (r"(?<![\w-])\.[\w-]*(token|secret|credential)",     "secret dotfile"),          # .api-token, .my-token (a jq `.token` reads as one: the cost of a net)
    (r"(^|/)(tokens?|secrets?|credentials?)/",           "secret directory"),
    (r"\.(netrc|pgpass|npmrc|pypirc)(?![\w-])|\.docker/config\.json|\.kube/config|\.config/(gh|gcloud|rclone)/|/etc/(shadow|sudoers)", "login store"),
]

# 4. The permission mode: a plan is read by a person before anything runs.
LEAVE_MODES = {"plan"}

# 5. What each tool carries that is scanned against the rules. A file tool: its path fields only (the content of an Edit is the
#    work, not the target). A shell tool: the command text. A tool in PROSE: nothing (its input is a prompt or a query). Any other
#    tool, an MCP server's included: every string in its input (the brief: "MCP input mentioning …").
PATH_TOOLS = {"Read", "Edit", "Write", "MultiEdit", "NotebookEdit", "NotebookRead", "Glob", "Grep", "LS"}
PATH_FIELDS = ("file_path", "notebook_path", "path", "paths", "glob", "directory")
WRITE_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}   # these also may not touch a hook script wired in the settings (WIRED below)
TEXT_TOOLS = {"Bash": ("command",), "PowerShell": ("command",), "Monitor": ("command",)}
PROSE_TOOLS = {"WebFetch", "WebSearch", "Agent", "Task", "TodoWrite", "Skill", "SendMessage", "ToolSearch", "TaskOutput", "TaskStop"}
# Glob's `pattern` is a path pattern; Grep's is a content regex and is not scanned.
# ══════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════

MAX_SCAN = 200000          # characters of one string looked at
MAX_STRINGS = 400          # strings of one input looked at
SNIP = 80                  # characters of the input in the log
LOG_MAX = 512 * 1024       # the log is cut to its last LOG_KEEP lines past this size
LOG_KEEP = 2000

RULES = [(re.compile(p, re.I), "surface: " + w) for p, w in SURFACE] + [(re.compile(p, re.I), "credentials: " + w) for p, w in CREDENTIALS]
HOME = os.path.expanduser("~")


def allow_text():
    return json.dumps({"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}}}, separators=(",", ":"))


def env_scrub():
    src = os.environ.get("SALA_SCRUB_PY")
    if src:
        ns = {}
        try:
            exec(src, ns)
            return ns["scrub"]
        except Exception:
            pass
    return lambda t: re.sub(r"(?i)((?:api[_-]?key|secret|token|password|passwd|credential|authorization)s?)(\s*[=:]\s*)\S+", r"\1\2…", t)


def log(line):
    path = os.environ.get("SALA_PERMISSION_LOG")
    if not path:
        return
    try:
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        with open(path, "a") as f:
            f.write("[%s] %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S%z"), line))
        if os.path.getsize(path) > LOG_MAX:                      # trimmed to its last lines, in place by a rename
            with open(path, encoding="utf-8", errors="replace") as f:
                keep = f.readlines()[-LOG_KEEP:]
            tmp = "%s.tmp.%d" % (path, os.getpid())
            with open(tmp, "w") as f:
                f.writelines(keep)
            os.replace(tmp, path)
    except OSError:
        pass


def strings(v, out, depth=0):
    """every string value of a JSON value, keys included, up to MAX_STRINGS"""
    if len(out) >= MAX_STRINGS or depth > 8:
        return
    if isinstance(v, str):
        out.append(v)
    elif isinstance(v, dict):
        for k, x in v.items():
            strings(k, out, depth + 1)
            strings(x, out, depth + 1)
    elif isinstance(v, (list, tuple)):
        for x in v:
            strings(x, out, depth + 1)


def collapse(s):
    """~, $HOME, /./ and x/../ resolved inside a text"""
    s = re.sub(r"(?<![\w$~])(~|\$HOME|\$\{HOME\})(?=/|\s|$|['\"])", HOME, s)
    s = re.sub(r"/\./", "/", s)
    for _ in range(20):
        t = re.sub(r"/[^/\s'\"`;|&()<>=]+/\.\.(?=/|\s|$|['\"])", "", s, count=1)
        if t == s:
            break
        s = t
    return s


def text_variants(s):
    s = s[:MAX_SCAN]
    c = collapse(s)
    q = re.sub(r"[\\'\"`]", "", c)                           # c\at ~/.ss""h/id: the quotes a shell takes out again
    return [s, c, q]


def path_variants(p, cwd):
    p = p[:4096]
    out = [p]
    try:
        e = os.path.expanduser(os.path.expandvars(p))        # ~, $HOME (expandvars needs HOME in the environment: it is)
        if not os.path.isabs(e) and cwd and os.path.isabs(cwd):
            e = os.path.join(cwd, e)
        n = os.path.normpath(e)
        out += [n, os.path.realpath(n)]
    except Exception:
        pass
    out += text_variants(p)[1:]
    return [v + "/" for v in out] + out                       # "hooks" as the last segment is a hooks directory too


def wired_scripts():
    """the paths of the scripts the settings wire as hooks (~/.claude/settings.json, settings.local.json): -> [absolute path]"""
    found = []
    for name in ("settings.json", "settings.local.json"):
        try:
            with open(os.path.join(HOME, ".claude", name), encoding="utf-8") as f:
                hooks = (json.load(f) or {}).get("hooks") or {}
        except Exception:
            continue
        cmds = []
        strings(hooks, cmds)
        for c in cmds:
            try:
                toks = shlex.split(c)
            except ValueError:
                toks = c.split()
            for t in toks:
                if "/" in t and not t.startswith("-"):
                    t = os.path.normpath(os.path.expanduser(os.path.expandvars(t)))
                    if os.path.isabs(t):
                        found.append(t)
    return found


def match(variants):
    for v in variants:
        for rx, why in RULES:
            if rx.search(v):
                return why
    return ""


def decide(d):
    """-> (True | False, reason)"""
    tool = d.get("tool_name")
    if not isinstance(tool, str) or not tool:
        return False, "no tool_name"
    if LEAVE_TOOLS.search(tool):
        return False, "asks a person"
    mode = d.get("permission_mode")
    if isinstance(mode, str) and mode in LEAVE_MODES:
        return False, "permission mode " + mode
    inp = d.get("tool_input")
    inp = inp if isinstance(inp, dict) else {}
    cwd = d.get("cwd") if isinstance(d.get("cwd"), str) else ""
    if tool in PATH_TOOLS:
        paths = []
        fields = PATH_FIELDS + (("pattern",) if tool == "Glob" else ())
        for k in fields:
            strings(inp.get(k), paths)
        for p in paths:
            why = match(path_variants(p, cwd))
            if why:
                return False, why
        if tool in WRITE_TOOLS and paths:
            wired = wired_scripts()
            if wired:
                for p in paths:
                    for v in path_variants(p, cwd):
                        if v.rstrip("/") in wired:
                            return False, "surface: a hook script wired in the settings"
    elif tool in TEXT_TOOLS:
        texts = []
        for k in TEXT_TOOLS[tool]:
            strings(inp.get(k), texts)
        for t in texts:
            why = match(text_variants(t))
            if why:
                return False, why
    elif tool not in PROSE_TOOLS:
        texts = []
        strings(inp, texts)
        for t in texts:
            why = match(text_variants(t))
            if why:
                return False, why
    return True, "no rule matched"


def snippet(d, scrub):
    """the first 80 characters of what the call is about, masked"""
    inp = d.get("tool_input") if isinstance(d.get("tool_input"), dict) else {}
    s = ""
    for k in ("command", "file_path", "notebook_path", "path", "url", "pattern", "query"):
        if isinstance(inp.get(k), str):
            s = inp[k]
            break
    if not s:
        parts = []
        strings(inp, parts)
        s = " ".join(parts[:4])
    s = " ".join(s.split())
    s = scrub(s[:400])
    return s[:SNIP] + ("…" if len(s) > SNIP else "")


def clean(x, n=40):
    return re.sub(r"[^\w.:@/+-]", "_", str(x))[:n] if x else "-"


def main():
    raw, d = "", None
    try:
        raw = sys.stdin.read()
        d = json.loads(raw) if raw.strip() else None
    except Exception:
        d = None
    why, ok, tool = "", False, "-"
    if not isinstance(d, dict):
        why = "empty input" if not raw.strip() else "input is not a JSON object"
        d = {}
    else:
        try:
            if os.environ.get("SALA_PERMISSION_APPROVE", "on").lower() in ("off", "0", "no", "false"):
                ok, why = False, "SALA_PERMISSION_APPROVE=off"
            else:
                ok, why = decide(d)
        except Exception as e:
            ok, why = False, "error " + type(e).__name__
    if isinstance(d.get("tool_name"), str):
        tool = clean(d["tool_name"], 60)
    try:
        scrub = env_scrub()
        sid = clean((d.get("session_id") or "")[:8] if isinstance(d.get("session_id"), str) else "", 8)
        agent = clean(d.get("agent_type") or d.get("agent_id") or os.environ.get("SALA_SESSION_ID") or os.environ.get("SALA_RC_NAME"))
        log("%s tool=%s why=%s session=%s agent=%s input=%s" % ("allowed" if ok else "left", tool, why, sid, agent, snippet(d, scrub)))
    except Exception:
        pass
    if ok:
        sys.stdout.write(allow_text() + "\n")


if __name__ == "__main__":
    try:
        main()
    except BaseException:
        pass
    sys.exit(0)
