#!/usr/bin/env python3
"""guard.py — the briefing's PreToolUse hook: only Gmail reads may go through the MCP Portal.

Why. The digests (summary.sh, defunct.sh) read the owner's mailbox with the portal tool
`mcp__mcp-portal__portal_codemode_execute`: the model writes a JavaScript arrow function and the portal runs it with a
`codemode` object whose methods are every tool of every connected server (Gmail, Drive, Calendar, Docs and
whatever else is connected). `--allowedTools` can only allow or refuse that one tool as a whole; it cannot see which `codemode.<tool>`
the code calls. So a prompt injection in an email (an instruction the model follows) could make a run send mail, draft,
label, or touch Drive and Calendar, and lib.sh's `portal_writes` would only notice afterwards. This hook runs BEFORE the
tool and refuses anything that is not plainly a Gmail read.

What it does. It reads the PreToolUse JSON on stdin (tool_name, tool_input) and prints a deny decision, or nothing:
  - a tool whose name does not start with `mcp__` (Read, Write, Bash, ToolSearch, ...): untouched;
  - `mcp__mcp-portal__portal_codemode_search`: allowed (it only lists tools);
  - `mcp__mcp-portal__portal_codemode_execute`: allowed only when its `code` passes the checks below;
  - any other `mcp__mcp-portal__*` tool (the server toggles): refused, the briefing never needs them;
  - any other `mcp__*` tool whose name carries a write verb (send, draft, create, update, delete, trash, label, modify,
    share, manage, move, upload, forward, reply, remove, insert, append, toggle): refused by name; the rest (the direct
    connector's Gmail reads) untouched. --allowedTools already keeps these out; this is belt and braces.

The code check is an ALLOW list on a conservative tokenization, never a search for bad names:
  1. `code` is a non-empty string, ASCII outside string, template, regex and comment literals, and tokenizes cleanly
     (an unterminated literal or comment, a backslash outside a literal, `#`, `@`, `<!--` all refuse);
  2. it is one `async () => ...` arrow function with no parameters, nothing after it;
  3. no `this`, `with`, `import`, `export`, `class`, `super`, `delete`, `void`, `debugger`, `yield`, no `new.`;
  4. the identifier `codemode` appears only as `codemode.<read>(` where <read> is one of the five Gmail reads
     (READS below), and a `g<word>_*` name (PREFIX below) appears only there; no `codemode` or `g<word>_` text inside any literal;
  5. no computed member access `x[...]` except a single numeric index (`[0]`, `[1]`), no optional chaining on codemode;
  6. no reflective or global-reaching name in any position (constructor, prototype, __proto__, call, apply, bind,
     Function, eval, Reflect, Proxy, globalThis, self, window, global, arguments, Symbol, the Object.*Property*
     and *PrototypeOf methods, require, process, fetch, ...: REFLECTIVE below);
  7. every other identifier is either a property name after `.`, a key in an object literal, a safe global (JSON,
     Promise, Math, String, Number, Array, Object, Date, RegExp, Set, Map, Boolean, URL, ...: SAFE_GLOBALS) or a
     name declared in an enclosing scope of the code itself (const/let/var, function and arrow parameters, catch,
     for heads); default values and computed keys in patterns refuse. An unknown free identifier refuses: the portal
     puts `codemode` and its own helpers in the scope around the code, and nothing there but the five reads is the
     briefing's to use.
Comments are dropped before the checks; strings, templates and regexes are opaque except for rule 4; `${...}` inside a
template is checked as code. The checks over-refuse by design: a refusal tells the model what was refused and why, and
the model rewrites the call (the shapes of real calls all pass: tests/briefing/readguard.sh).

Limits. This blocks the portal path of the two digest runs, where lib.sh passes it with `--settings` (the cli path and
the Agent SDK path alike); no other session loads it. It is a second wall beside `--allowedTools` and ahead of the
after-the-fact `portal_writes` check, not the only one: it cannot judge what a Gmail read is used for, it trusts the
portal to expose tools only through `codemode`, and JavaScript it cannot tokenize is refused rather than understood.
Every decision is appended to the log (--log): time, tool, decision, the codemode names seen, the reason; never the
code or a query.

Usage (from the settings JSON lib.sh builds):  python3 -I guard.py [--log <file>]  < PreToolUse JSON
Exit 0 always; a deny is the JSON on stdout. Malformed stdin refuses too (fail closed), as does any error in here.
"""
import json
import os
import re
import sys
import time

TOOL_EXECUTE = "mcp__mcp-portal__portal_codemode_execute"
TOOL_SEARCH = "mcp__mcp-portal__portal_codemode_search"
PORTAL_PREFIX = "mcp__mcp-portal__"
# The five Gmail reads of the portal's Google Workspace server, as the runs' logs call them (summary.<date>.jsonl,
# defunct.<date>.jsonl: search, get_gmail_message_content, get_gmail_messages_content_batch used; the two thread reads named
# in the prompts and in lib.sh's PORTAL_GMAIL_READS). The portal names them g<word>_<read>, <word> the connector's word in
# lower case: BRIEFING_GMAIL_CONNECTOR, which lib.sh exports (from the environment or the sala config). Unset, empty or not
# one word: no prefix and no read, so every portal call is refused.
READ_NAMES = ("search_gmail_messages", "get_gmail_message_content", "get_gmail_messages_content_batch",
              "get_gmail_thread_content", "get_gmail_threads_content_batch")
_CONNECTOR = os.environ.get("BRIEFING_GMAIL_CONNECTOR", "")
PREFIX = "g" + _CONNECTOR.lower() + "_" if re.fullmatch(r"[A-Za-z0-9]+", _CONNECTOR) else ""
READS = {PREFIX + r for r in READ_NAMES} if PREFIX else set()
WRITE_WORDS = ("send", "draft", "create", "update", "delete", "trash", "label", "modify", "share", "manage", "move",
               "upload", "forward", "reply", "remove", "insert", "append", "toggle")

KEYWORDS_OK = {"async", "await", "const", "let", "var", "return", "if", "else", "for", "of", "in", "while", "do",
               "break", "continue", "new", "typeof", "instanceof", "try", "catch", "finally", "throw", "function",
               "true", "false", "null", "switch", "case", "default"}
KEYWORDS_NO = {"this", "with", "import", "export", "class", "super", "delete", "void", "debugger", "yield", "extends",
               "enum", "static", "implements", "interface", "package", "private", "protected", "public"}
SAFE_GLOBALS = {"JSON", "Promise", "Math", "String", "Number", "Array", "Object", "Date", "RegExp", "Set", "Map",
                "Boolean", "parseInt", "parseFloat", "isNaN", "isFinite", "encodeURIComponent", "decodeURIComponent",
                "encodeURI", "decodeURI", "undefined", "NaN", "Infinity", "console", "Error", "TypeError", "RangeError",
                "URL", "URLSearchParams"}
# Refused as a token in any position: these reach other objects, the global object or the enclosing scope.
REFLECTIVE = {"constructor", "prototype", "__proto__", "call", "apply", "bind", "Function", "AsyncFunction",
              "GeneratorFunction", "eval", "Reflect", "Proxy", "globalThis", "self", "window", "global", "arguments",
              "Symbol", "getPrototypeOf", "setPrototypeOf", "getOwnPropertyDescriptor", "getOwnPropertyDescriptors",
              "getOwnPropertyNames", "getOwnPropertySymbols", "defineProperty", "defineProperties", "require",
              "process", "fetch", "WebAssembly", "queueMicrotask", "setTimeout", "setInterval", "importScripts"}

PUNCT = sorted(["{", "}", "(", ")", "[", "]", ";", ",", "<", ">", "<=", ">=", "==", "!=", "===", "!==", "+", "-", "*",
                "/", "%", "**", "++", "--", "<<", ">>", ">>>", "&", "|", "^", "!", "~", "&&", "||", "??", "?", "?.", ":",
                "=", "+=", "-=", "*=", "/=", "%=", "**=", "<<=", ">>=", ">>>=", "&=", "|=", "^=", "&&=", "||=", "??=",
                "=>", "...", "."], key=len, reverse=True)
OPENERS = {"(": ")", "[": "]", "{": "}", "${": "}"}
ID_RE = re.compile(r"[A-Za-z_$][A-Za-z0-9_$]*")
NUM_RE = re.compile(r"(?:0[xob][0-9a-f_]+|(?:[0-9][0-9_]*(?:\.[0-9_]*)?|\.[0-9][0-9_]*)(?:e[+-]?[0-9]+)?)n?", re.I)
# After one of these a `/` starts a regular expression, not a division.
REGEX_AFTER_PUNCT = {"(", ",", "=", ":", "[", "!", "&", "|", "?", "{", "}", ";", "+", "-", "*", "%", "<", ">", "~", "^",
                     "=>", "&&", "||", "??", "==", "!=", "===", "!==", "<=", ">=", "+=", "-=", "*=", "/=", "**", "${"}
REGEX_AFTER_WORD = {"return", "typeof", "instanceof", "in", "of", "new", "throw", "case", "do", "else", "await"}


class Refuse(Exception):
    pass


class Tok:
    __slots__ = ("kind", "text", "pos")

    def __init__(self, kind, text, pos):
        self.kind, self.text, self.pos = kind, text, pos   # kind: id | kw | num | str | re | punct

    def __repr__(self):
        return f"{self.kind}:{self.text}"


def tokenize(src):
    """The token list of src, comments dropped, strings/templates/regexes as single opaque tokens (a template's ${...}
    parts are tokenized as code between `${` and `}` tokens). Raises Refuse on anything outside the accepted lexicon."""
    toks = []
    i, n = 0, len(src)
    tmpl_depth = []   # brace depth inside each open ${ so its closing } is found

    def regex_allowed():
        if not toks:
            return True
        p = toks[-1]
        if p.kind == "punct":
            return p.text in REGEX_AFTER_PUNCT
        return p.kind == "kw" and p.text in REGEX_AFTER_WORD

    def scan_string(q, start):
        j = start + 1
        while j < n:
            c = src[j]
            if c == "\\":
                j += 2
                continue
            if c == "\n":
                raise Refuse("an unterminated string literal")
            if c == q:
                return j + 1
            j += 1
        raise Refuse("an unterminated string literal")

    def scan_regex(start):
        j, in_class = start + 1, False
        while j < n:
            c = src[j]
            if c == "\\":
                j += 2
                continue
            if c == "\n":
                raise Refuse("a regular expression literal that does not close")
            if in_class:
                if c == "]":
                    in_class = False
            elif c == "[":
                in_class = True
            elif c == "/":
                j += 1
                while j < n and src[j].isalpha():
                    j += 1
                return j
            j += 1
        raise Refuse("a regular expression literal that does not close")

    def scan_template_text(start):
        """From start (just after a backtick or a closing }): the text up to and including the closing backtick, or
        up to a `${` (which is emitted as a token). Returns the next index."""
        j = start
        while j < n:
            d = src[j]
            if d == "\\":
                j += 2
                continue
            if d == "`":
                toks.append(Tok("str", src[start:j + 1], start))
                return j + 1
            if src.startswith("${", j):
                toks.append(Tok("str", src[start:j], start))
                toks.append(Tok("punct", "${", j))
                tmpl_depth.append(0)
                return j + 2
            j += 1
        raise Refuse("an unterminated template literal")

    while i < n:
        c = src[i]
        if c in " \t\r\n":
            i += 1
            continue
        if src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
            continue
        if src.startswith("/*", i):
            j = src.find("*/", i + 2)
            if j < 0:
                raise Refuse("an unterminated comment")
            i = j + 2
            continue
        if src.startswith("<!--", i) or src.startswith("-->", i):
            raise Refuse("an HTML-style comment")
        if c in "'\"":
            j = scan_string(c, i)
            toks.append(Tok("str", src[i:j], i))
            i = j
            continue
        if c == "`":
            i = scan_template_text(i + 1)
            continue
        if c == "}" and tmpl_depth and tmpl_depth[-1] == 0:
            tmpl_depth.pop()
            toks.append(Tok("punct", "}", i))
            i = scan_template_text(i + 1)
            continue
        if c == "/" and regex_allowed():
            j = scan_regex(i)
            toks.append(Tok("re", src[i:j], i))
            i = j
            continue
        if c.isdigit() or (c == "." and i + 1 < n and src[i + 1].isdigit()):
            m = NUM_RE.match(src, i)
            toks.append(Tok("num", m.group(0), i))
            i = m.end()
            continue
        m = ID_RE.match(src, i)
        if m:
            w = m.group(0)
            if w in KEYWORDS_NO:
                raise Refuse(f"the keyword `{w}`")
            toks.append(Tok("kw" if w in KEYWORDS_OK else "id", w, i))
            i = m.end()
            continue
        for p in PUNCT:
            if src.startswith(p, i):
                if tmpl_depth:
                    if p == "{":
                        tmpl_depth[-1] += 1
                    elif p == "}":
                        tmpl_depth[-1] -= 1
                toks.append(Tok("punct", p, i))
                i += len(p)
                break
        else:
            if c == "\\":
                raise Refuse("a backslash outside a literal (an escaped identifier)")
            if ord(c) > 127:
                raise Refuse("a non-ASCII character outside a literal")
            raise Refuse(f"the character `{c}`")
    if tmpl_depth:
        raise Refuse("an unterminated template literal")
    return toks


def is_p(t, *texts):
    return t is not None and t.kind == "punct" and t.text in texts


def match_group(toks, i):
    """Index of the closer matching the opener at toks[i]."""
    d = 0
    for j in range(i, len(toks)):
        t = toks[j]
        if t.kind == "punct":
            if t.text in OPENERS:
                d += 1
            elif t.text in (")", "]", "}"):
                d -= 1
                if d == 0:
                    return j
    raise Refuse("an unbalanced bracket")


def pattern_end(toks, i):
    """End (exclusive) of a binding pattern starting at toks[i]: the first `=`, `of`, `in`, `;` or `,` at its own
    nesting level, or the closer of the enclosing group."""
    d, j, n = 0, i, len(toks)
    while j < n:
        t = toks[j]
        if t.kind == "punct":
            if t.text in OPENERS:
                d += 1
            elif t.text in (")", "]", "}"):
                if d == 0:
                    return j
                d -= 1
            elif d == 0 and t.text in ("=", ";", ","):
                return j
        elif d == 0 and t.kind == "kw" and t.text in ("of", "in"):
            return j
        j += 1
    return j


def bind_pattern(toks, i, end, names, where):
    """Add to names what the binding pattern toks[i:end] declares: identifiers, `{…}` / `[…]` patterns with nesting,
    `...rest`, `key: name` inside an object pattern. A default value (`=`) or a computed key refuses: a default is an
    expression evaluated in the outer scope, and this reader does not follow it."""
    j, in_obj = i, []   # in_obj: True for each enclosing object pattern
    while j < end:
        t = toks[j]
        if t.kind == "punct":
            if t.text == "{":
                in_obj.append(True)
            elif t.text == "[":
                if in_obj and in_obj[-1]:
                    raise Refuse(f"a computed key in {where}")
                in_obj.append(False)
            elif t.text in ("}", "]"):
                if not in_obj or in_obj.pop() != (t.text == "}"):
                    raise Refuse(f"an unbalanced pattern in {where}")
            elif t.text in (",", "..."):
                pass
            elif t.text == ":" and in_obj and in_obj[-1]:
                pass   # what follows the key is the binding
            elif t.text == "=":
                raise Refuse(f"a default value in {where}")
            else:
                raise Refuse(f"`{t.text}` in {where}")
        elif t.kind == "id":
            if in_obj and in_obj[-1] and is_p(toks[j + 1] if j + 1 < end else None, ":"):
                pass   # `key:` in an object pattern
            else:
                names.add(t.text)
        else:
            raise Refuse(f"`{t.text}` in {where}")
        j += 1
    if in_obj:
        raise Refuse(f"an unbalanced pattern in {where}")


class Scope:
    __slots__ = ("names", "kind", "depth")

    def __init__(self, kind, depth, names=()):
        self.names, self.kind, self.depth = set(names), kind, depth   # kind: block | expr | head


def check_code(code):
    """Raises Refuse with the reason, or returns the sorted codemode names the code calls."""
    if not isinstance(code, str) or not code.strip():
        raise Refuse("no code string")
    toks = tokenize(code)
    n = len(toks)

    def at(k):
        return toks[k] if 0 <= k < n else None

    # 2. one `async () => ...`, nothing after it (a top-level `;` may end a block body)
    if not (n >= 5 and toks[0].kind == "kw" and toks[0].text == "async" and is_p(toks[1], "(")
            and is_p(toks[2], ")") and is_p(toks[3], "=>")):
        raise Refuse("code that is not one `async () => ...` arrow function without parameters")
    if is_p(toks[4], "{"):
        end = match_group(toks, 4)
        if end < n - 1 and not (end == n - 2 and is_p(toks[n - 1], ";")):
            raise Refuse("code after the arrow function")

    # 4. literals: no codemode or g<word>_ text inside a string, template or regex
    banned = r"codemode" + ("|" + re.escape(PREFIX) if PREFIX else "")
    for t in toks:
        if t.kind in ("str", "re") and re.search(banned, t.text, re.I):
            raise Refuse(f"the text `codemode` or `{PREFIX or 'g<word>_'}` inside a literal")

    # 6. reflective names in any position; 4. codemode / g<word>_ only in the allowed form; 3. `new.`
    called = set()
    for k, t in enumerate(toks):
        if t.kind == "kw":
            if t.text == "new" and is_p(at(k + 1), "."):
                raise Refuse("`new.`")
            continue
        if t.kind != "id":
            continue
        if t.text in REFLECTIVE:
            raise Refuse(f"the name `{t.text}`")
        if t.text == "codemode":
            nm = at(k + 2)
            if not (is_p(at(k + 1), ".") and nm is not None and nm.kind == "id" and nm.text in READS and is_p(at(k + 3), "(")):
                if is_p(at(k + 1), ".") and nm is not None and nm.kind == "id" and nm.text not in READS:
                    raise Refuse(f"codemode.{nm.text}: not one of the five Gmail reads")
                raise Refuse("`codemode` used other than as codemode.<gmail read>(...)")
            called.add(nm.text)
        elif PREFIX and t.text.startswith(PREFIX):
            p2 = at(k - 2)
            if not (t.text in READS and is_p(at(k - 1), ".") and p2 is not None and p2.kind == "id" and p2.text == "codemode"):
                raise Refuse(f"the name `{t.text}` outside codemode.<gmail read>(...)")

    # 5 and 7: brackets, scopes, declarations, free identifiers
    scopes = [Scope("block", 0)]
    openers = []            # (text, kind) for each open ( [ { ${ ; kind: block|object for {, index|array for [
    consumed = set()        # token indices read as binders
    arrow_params = {}       # index of a `=>` -> the names its ( ) parameter list binds
    pending_params = None   # names to bind in the block that opens next (a function or arrow body)
    decl_depth = None       # depth of the const/let/var declaration list being read
    for_head = None         # depth inside a `for (` head whose scope waits for its body
    prev_close_object = False   # the previous token was the } of an object literal

    def depth():
        return len(openers)

    def declared(name):
        return any(name in s.names for s in scopes)

    def pop_expr_scopes(d, closer):
        # an arrow's expression body ends at a `,` or `;` at its depth, or when its enclosing group closes; a for
        # head's scope ends only with its body (the block close below, or the statement for a braceless body)
        while len(scopes) > 1 and scopes[-1].kind == "expr" and (scopes[-1].depth > d or
                                                                   (scopes[-1].depth == d and not closer)):
            scopes.pop()

    k = 0
    while k < n:
        t = toks[k]
        if k in consumed:
            prev_close_object = False
            k += 1
            continue
        nxt, prv = at(k + 1), at(k - 1)
        was_close_object, prev_close_object = prev_close_object, False
        if t.kind == "punct":
            if t.text in OPENERS:
                if pending_params is not None and t.text != "{":
                    raise Refuse("a function whose body is not a block")
                kind = ""
                if t.text == "{":
                    if prv is not None and ((prv.kind == "punct" and prv.text in ("=", "(", ",", ":", "[", "?", "||",
                                                                                   "&&", "??", "${"))
                                            or (prv.kind == "kw" and prv.text in ("return", "case", "await", "typeof",
                                                                                  "in", "of"))):
                        kind = "object"
                    else:
                        kind = "block"
                        scopes.append(Scope("block", depth() + 1, pending_params or ()))
                        pending_params = None
                elif t.text == "[":
                    member = was_close_object or (prv is not None and (
                        prv.kind in ("id", "num", "str", "re") or (prv.kind == "punct" and prv.text in (")", "]"))
                        or (prv.kind == "kw" and prv.text in ("true", "false", "null"))))
                    kind = "index" if member else "array"
                    if member and not (nxt is not None and nxt.kind == "num" and is_p(at(k + 2), "]")):
                        raise Refuse("computed property access `[...]` that is not a single numeric index")
                elif t.text == "(":
                    close = match_group(toks, k)
                    if is_p(at(close + 1), "=>"):
                        names = set()
                        bind_pattern(toks, k + 1, close, names, "parameters")
                        consumed.update(range(k + 1, close))
                        arrow_params[close + 1] = names
                openers.append((t.text, kind))
            elif t.text in (")", "]", "}"):
                if not openers:
                    raise Refuse("an unbalanced bracket")
                otext, okind = openers.pop()
                if OPENERS[otext] != t.text:
                    raise Refuse("an unbalanced bracket")
                d = depth()
                if otext == "{" and okind == "block":
                    while len(scopes) > 1 and not (scopes[-1].kind == "block" and scopes[-1].depth == d + 1):
                        scopes.pop()
                    if len(scopes) == 1:
                        raise Refuse("an unbalanced block")
                    scopes.pop()
                    if scopes[-1].kind == "head" and scopes[-1].depth == d + 1:
                        scopes.pop()   # the for head's scope ends with its body
                prev_close_object = otext == "{" and okind == "object"
                pop_expr_scopes(d, closer=True)
                if otext == "(" and for_head is not None and for_head == d + 1:
                    for_head = None
                    if not is_p(nxt, "{"):   # a braceless for body: the head's scope ends with the statement
                        scopes[-1].kind = "expr"
                        scopes[-1].depth = d
                if decl_depth is not None and d < decl_depth:
                    decl_depth = None
            elif t.text in (",", ";"):
                pop_expr_scopes(depth(), closer=False)
                if t.text == ";":
                    if depth() == 0 and k != n - 1:
                        raise Refuse("more than one statement")
                    if decl_depth == depth():
                        decl_depth = None
                elif decl_depth == depth():   # `const a = 1, b = 2`: another pattern follows
                    end = pattern_end(toks, k + 1)
                    bind_pattern(toks, k + 1, end, scopes[-1].names, "a declaration")
                    consumed.update(range(k + 1, end))
            elif t.text == "=>":
                names = arrow_params.pop(k, None)
                if names is None:
                    if prv is not None and prv.kind == "id":
                        names = {prv.text}
                    else:
                        raise Refuse("an arrow function with unreadable parameters")
                if is_p(nxt, "{"):
                    pending_params = names
                else:
                    scopes.append(Scope("expr", depth(), names))
            k += 1
            continue
        if t.kind == "kw":
            if t.text in ("const", "let", "var"):
                if decl_depth is not None:
                    raise Refuse("a declaration inside a declaration")
                end = pattern_end(toks, k + 1)
                if end == k + 1:
                    raise Refuse("a declaration without a name")
                bind_pattern(toks, k + 1, end, scopes[-1].names, "a declaration")
                consumed.update(range(k + 1, end))
                decl_depth = depth()
                if end < n and toks[end].kind == "kw" and toks[end].text in ("of", "in"):
                    decl_depth = None
                k = end
                continue
            if t.text == "function":
                j = k + 1
                if j < n and toks[j].kind == "id":
                    scopes[-1].names.add(toks[j].text)
                    j += 1
                if not is_p(at(j), "("):
                    raise Refuse("a function without a parameter list")
                close = match_group(toks, j)
                names = set()
                bind_pattern(toks, j + 1, close, names, "parameters")
                if not is_p(at(close + 1), "{"):
                    raise Refuse("a function whose body is not a block")
                pending_params = names
                k = close + 1
                continue
            if t.text == "catch" and is_p(nxt, "("):
                close = match_group(toks, k + 1)
                names = set()
                bind_pattern(toks, k + 2, close, names, "catch")
                if not is_p(at(close + 1), "{"):
                    raise Refuse("a catch without a block")
                pending_params = names
                k = close + 1
                continue
            if t.text == "for" and is_p(nxt, "("):
                scopes.append(Scope("head", depth() + 1))
                for_head = depth() + 1
            k += 1
            continue
        if t.kind == "id":
            if t.text == "codemode" or is_p(prv, ".", "?."):
                k += 1
                continue   # codemode (its form was checked above) or a property name (the reflective ones refused above)
            if is_p(nxt, "=>"):
                k += 1
                continue   # a single arrow parameter, bound at the `=>`
            if is_p(nxt, ":") and is_p(prv, "{", ",") and openers and openers[-1][1] == "object":
                k += 1
                continue   # a key in an object literal
            if t.text in SAFE_GLOBALS or declared(t.text):
                k += 1
                continue
            raise Refuse(f"the unknown name `{t.text}`")
        k += 1
    if openers:
        raise Refuse("an unbalanced bracket")
    return sorted(called)


def decide(tool, tool_input):
    """(decision, reason, names): decision is 'allow' or 'deny'."""
    if not isinstance(tool, str) or not tool.startswith("mcp__"):
        return "allow", "not an MCP tool", []
    if tool == TOOL_SEARCH:
        return "allow", "lists tools only", []
    if tool == TOOL_EXECUTE:
        code = tool_input.get("code") if isinstance(tool_input, dict) else None
        try:
            names = check_code(code)
        except Refuse as e:
            return "deny", f"refused: {e}", []
        except Exception as e:   # a reader bug fails closed, and says so
            return "deny", f"refused: the code could not be read ({type(e).__name__})", []
        return "allow", "gmail reads only", names
    if tool.startswith(PORTAL_PREFIX):
        return "deny", "refused: a portal tool the briefing never uses", []
    short = tool.split("__", 2)[-1].lower()
    hit = [w for w in WRITE_WORDS if w in short]
    if hit:
        return "deny", f"refused: a Workspace tool that can write ({', '.join(hit)})", []
    return "allow", "not a write tool", []


def main(argv):
    log = argv[2] if len(argv) >= 3 and argv[1] == "--log" else None
    try:
        data = json.loads(sys.stdin.read() or "null")
    except Exception:
        data = None
    tool = data.get("tool_name") if isinstance(data, dict) else None
    if tool is None:
        decision, reason, names, tool = "deny", "refused: the hook input could not be read", [], "?"
    else:
        decision, reason, names = decide(tool, data.get("tool_input"))
    if log:
        try:
            with open(log, "a", encoding="utf-8") as f:
                f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S%z')} {tool} {decision} [{' '.join(names)}] {reason}\n")
        except OSError:
            pass
    if decision == "deny":
        why = ("[briefing-guard] This run may only READ Gmail through the portal: codemode.<one of "
               + (", ".join(sorted(READS)) or "the Gmail reads: none, BRIEFING_GMAIL_CONNECTOR is not set") + ">(...) inside one `async () => ...`, nothing else. "
               + reason[0].upper() + reason[1:] + ". Rewrite the call with only those reads; do not send, draft, "
               "label or change anything.")
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                                 "permissionDecisionReason": why}}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
