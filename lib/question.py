#!/usr/bin/env python3
"""lib/question.py — the data half of the parked-question flow (Thu Oct 22nd 2026; lib/question.sh is the
shell half and holds the header that explains the flow). Standard library only; run as `python3 -I -S question.py <mode> …`.

  hook                       the PreToolUse hook (`salamander hook ask`): payload on stdin, the decision JSON on stdout (nothing
                             for "not mine"). Needs SALA_STATE_DIR; SALA_DEFER_TOOLS (default AskUserQuestion); SALA_BIN to file.
  answer <qid> [--decline [reason] | --free-text] [--check] <text>
                             validate the owner's words against the parked call and store the decision the hook will return
                             (exit 0 stored · 2 no such record · 3 the words do not fit, the reason on stderr · 4 already done)
  show <qid>                 one TSV line: state, session id, cwd, permission mode, tool, item, label, filed
  set <qid> <key> <value> [<key> <value> …]
                             string fields of the record (item, filed), in one start
  text <qid>                 the question as plain words, for the post and the board item (the shell scrubs it)
  finish <qid>               mark the record done (what a resume that ended well does when the hook has not already)
  list                       the parked and answered records, one line each
  sweep                      the same records, each as `<qid> TAB <the show row>` (the sweep asks once for all of them)
  result                     a `claude -p --output-format json` result on stdin (the last JSON-object line when there is noise ahead of it): "parked<TAB>qid<TAB>session" or "done<TAB>-<TAB>session",
                             then the result text ("error" likewise for a failed run or a deferral with no record, exit 1)
  settings-json / host-json  the --settings and --mcp-config values a background run is started with

A record is $SALA_STATE_DIR/questions/<qid>/record.json (0600 in a 0700 directory; it holds the call's input, which the
resume echoes back). qid = the first 12 hex digits of sha1(session id, NUL, tool_use id): the same call always has the same qid,
so a hook that fires twice, or again on the resume, finds its record and never files a second time."""
import hashlib, json, os, re, shlex, subprocess, sys, time

OWNER = os.environ.get("SALA_OWNER_NAME") or "the owner"   # common.sh exports SALA_OWNER_NAME; the words below name who answered
OWNER_CAP = OWNER[:1].upper() + OWNER[1:]                  # for a sentence that starts with the name

STATE = os.environ.get("SALA_STATE_DIR", "")
QDIR = os.path.join(STATE, "questions") if STATE else ""
YES = {"yes", "y", "ok", "okay", "allow", "approve", "approved", "go", "proceed", "sure", "yep", "yeah"}
NO = {"no", "n", "deny", "denied", "decline", "declined", "refuse", "refused", "reject", "rejected", "stop", "cancel", "nope"}


def qid_of(session_id, tool_use_id):
    return hashlib.sha1(("%s\0%s" % (session_id, tool_use_id)).encode()).hexdigest()[:12]


def rpath(qid):
    return os.path.join(QDIR, qid, "record.json")


def load(qid):
    try:
        with open(rpath(qid)) as f:
            r = json.load(f)
        return r if isinstance(r, dict) else None
    except Exception:
        return None


def save(qid, rec):
    d = os.path.join(QDIR, qid)
    os.makedirs(d, mode=0o700, exist_ok=True)
    tmp = os.path.join(d, ".record.%d" % os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(rec, f, indent=1)
    os.replace(tmp, rpath(qid))


def defer_tools():
    return [t for t in os.environ.get("SALA_DEFER_TOOLS", "AskUserQuestion").split() if re.fullmatch(r"[A-Za-z0-9_]+", t)]


def out(decision, reason=None, updated=None):
    h = {"hookEventName": "PreToolUse", "permissionDecision": decision}
    if reason:
        h["permissionDecisionReason"] = reason
    if updated is not None:
        h["updatedInput"] = updated
    print(json.dumps({"hookSpecificOutput": h}))


def questions_of(tool_input):
    qs = tool_input.get("questions") if isinstance(tool_input, dict) else None
    return [q for q in qs if isinstance(q, dict) and isinstance(q.get("question"), str)] if isinstance(qs, list) else []


def mode_hook():
    d = json.load(sys.stdin)
    tool, sid, tuid = d.get("tool_name"), d.get("session_id"), d.get("tool_use_id")
    if not (STATE and isinstance(tool, str) and isinstance(sid, str) and isinstance(tuid, str) and sid and tuid):
        return
    if tool not in defer_tools():
        return
    qid = qid_of(sid, tuid)
    rec = load(qid)
    tin = d.get("tool_input") if isinstance(d.get("tool_input"), dict) else {}
    if rec is None:
        rec = {"qid": qid, "session_id": sid, "tool_use_id": tuid, "tool": tool, "tool_input": tin,
               "cwd": d.get("cwd") or "", "permission_mode": d.get("permission_mode") or "default",
               "label": os.environ.get("SALA_QUESTION_LABEL") or os.path.basename(d.get("cwd") or "") or "a background run",
               "created": int(time.time()), "state": "parked", "item": "", "filed": ""}
        save(qid, rec)
        b = os.environ.get("SALA_BIN")
        if b:   # file it now (the board item / the post); a failure leaves filed empty, and `question sweep` files it later
            try:
                subprocess.run([b, "question", "file", qid], timeout=25, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except Exception:
                pass
        return out("defer")
    if rec.get("state") == "answered" and rec.get("decision") in ("allow", "deny"):
        if rec["decision"] == "deny":
            rec["state"] = "done"; rec["done"] = int(time.time()); save(qid, rec)
            return out("deny", rec.get("reason") or OWNER_CAP + " declined; nothing was granted")
        if tool == "AskUserQuestion":
            qs = questions_of(tin)
            ans = rec.get("answers") if isinstance(rec.get("answers"), dict) else {}
            if not qs or not ans or set(ans) != {q["question"] for q in qs}:   # the call is not the one that was answered: park it again
                return out("defer")
            rec["state"] = "done"; rec["done"] = int(time.time()); save(qid, rec)
            return out("allow", updated={"questions": tin.get("questions"), "answers": ans})
        rec["state"] = "done"; rec["done"] = int(time.time()); save(qid, rec)
        return out("allow", OWNER_CAP + " approved this call")
    if rec.get("state") == "done":
        return   # answered and used already: the normal flow decides (a repeat of the call is not the answered one)
    return out("defer")   # parked, no answer yet: stay parked


def match_option(q, token, free_text):
    t = token.strip().strip("\"'").strip()
    opts = [o.get("label") for o in q.get("options", []) if isinstance(o, dict) and isinstance(o.get("label"), str)]
    if re.fullmatch(r"\d+", t) and 1 <= int(t) <= len(opts):
        return opts[int(t) - 1]
    for o in opts:
        if o.lower() == t.lower():
            return o
    if free_text and t:
        return t
    raise ValueError("%r is not one of the options (%s); use its label or its number, or --free-text" % (t, " / ".join("%d. %s" % (i + 1, o) for i, o in enumerate(opts))))


def one_answer(q, text, free_text):
    if q.get("multiSelect"):
        parts = [p for p in re.split(r"\s*,\s*", text.strip()) if p]
        if not parts:
            raise ValueError("an empty answer")
        return ", ".join(match_option(q, p, free_text) for p in parts)
    return match_option(q, text, free_text)


def parse_answers(qs, text, free_text):
    text = re.sub(r"(?i)^\s*(answer|reply)\s*[:\-]\s*", "", text.strip())
    if not text:
        raise ValueError("an empty answer")
    if len(qs) == 1:
        return {qs[0]["question"]: one_answer(qs[0], text, free_text)}
    res = {}
    for line in [l for l in text.splitlines() if l.strip()]:
        m = re.match(r"^\s*(\d+)\s*[.:=)\-]\s*(.+)$", line)
        if m and 1 <= int(m.group(1)) <= len(qs):
            q = qs[int(m.group(1)) - 1]; ans = m.group(2)
        else:
            m = re.match(r"^\s*(.+?)\s*[:=]\s*(.+)$", line)
            q = next((x for x in qs if m and m.group(1).strip().lower() in (x["question"].lower(), str(x.get("header", "")).lower())), None)
            if q is None:
                raise ValueError("with %d questions, answer each on its own line as '1: label' (or the question's header)" % len(qs))
            ans = m.group(2)
        res[q["question"]] = one_answer(q, ans, free_text)
    missing = [q["question"] for q in qs if q["question"] not in res]
    if missing:
        raise ValueError("no answer for: %s" % "; ".join(missing))
    return res


def mode_answer(argv):
    decline = free = check = False; reason = ""; words = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--decline":
            decline = True
            if i + 1 < len(argv) and not argv[i + 1].startswith("--"):
                i += 1; reason = argv[i]
        elif a == "--free-text": free = True
        elif a == "--check": check = True
        else: words.append(a)
        i += 1
    if not words:
        print("answer: needs the question id", file=sys.stderr); return 2
    qid, text = words[0], " ".join(words[1:])
    rec = load(qid)
    if rec is None:
        print("no parked question %s" % qid, file=sys.stderr); return 2
    if rec.get("state") == "done":
        print("question %s is finished already" % qid, file=sys.stderr); return 4
    try:
        if decline:
            rec.update(decision="deny", reason=(OWNER_CAP + " declined: " + reason) if reason else OWNER_CAP + " declined; nothing was granted")
            rec.pop("answers", None)
        elif rec.get("tool") == "AskUserQuestion":
            qs = questions_of(rec.get("tool_input"))
            if not qs:
                raise ValueError("the parked call carries no questions")
            rec.update(decision="allow", answers=parse_answers(qs, text, free)); rec.pop("reason", None)
        else:
            w = re.sub(r"[^a-z ]", " ", text.lower()).split()
            if w and w[0] in YES: rec.update(decision="allow"); rec.pop("reason", None)
            elif w and w[0] in NO: rec.update(decision="deny", reason=OWNER_CAP + " said no: " + text.strip()[:300])
            else: raise ValueError("answer yes (allow this call) or no (deny it)")
    except ValueError as e:
        print("the answer does not fit question %s: %s" % (qid, e), file=sys.stderr); return 3
    if not check:
        rec.update(state="answered", answered=int(time.time())); save(qid, rec)
    print(json.dumps(rec.get("answers") if rec["decision"] == "allow" and rec.get("answers") else {"decision": rec["decision"]}, ensure_ascii=False))
    return 0


def mode_show(qid):
    r = load(qid)
    if r is None: return 2
    f = lambda k: str(r.get(k, "") or "-").replace("\t", " ").replace("\n", " ")
    print("\t".join(f(k) for k in ("state", "session_id", "cwd", "permission_mode", "tool", "item", "label", "filed")))
    return 0


def mode_sweep():
    """Every open question as `<qid>\t<show row>` (the row `show` prints), so a sweep asks once for all of them."""
    try: names = sorted(os.listdir(QDIR))
    except Exception: names = []
    for qid in names:
        r = load(qid)
        if not r or r.get("state") == "done": continue
        f = lambda k: str(r.get(k, "") or "-").replace("\t", " ").replace("\n", " ")
        print(qid + "\t" + "\t".join(f(k) for k in ("state", "session_id", "cwd", "permission_mode", "tool", "item", "label", "filed")))
    return 0


def mode_set(qid, *kv):
    r = load(qid)
    if r is None or any(k not in ("item", "filed") for k in kv[0::2]): return 2
    for k, v in zip(kv[0::2], kv[1::2]): r[k] = v
    save(qid, r); return 0


def mode_text(qid):
    r = load(qid)
    if r is None: return 2
    tin = r.get("tool_input") or {}
    if r.get("tool") == "AskUserQuestion":
        for i, q in enumerate(questions_of(tin)):
            opts = [o.get("label") for o in q.get("options", []) if isinstance(o, dict)]
            print("%s%s%s" % ("%d. " % (i + 1) if len(questions_of(tin)) > 1 else "", q["question"], "  [" + " / ".join(str(o) for o in opts) + "]" if opts else ""))
    else:
        cmd = tin.get("command") or tin.get("url") or tin.get("file_path") or tin.get("path") or json.dumps(tin, ensure_ascii=False)
        print("%s wants to run %s: %s" % (r.get("label"), r.get("tool"), " ".join(str(cmd).split())[:300]))
    return 0


def mode_list():
    now = int(time.time())
    try: names = sorted(os.listdir(QDIR))
    except Exception: names = []
    for qid in names:
        r = load(qid)
        if not r or r.get("state") == "done": continue
        qs = questions_of(r.get("tool_input"))
        first = qs[0]["question"] if qs else (r.get("tool") or "")
        print("%s\t%s\t%s\t%s\t%dm\t%s\t%s" % (qid, r.get("state"), r.get("tool"), r.get("label"), (now - int(r.get("created", now))) // 60, r.get("item") or "-", " ".join(first.split())[:80]))
    return 0


def parse_result(text):
    """The result object in `claude -p --output-format json` output: the whole text when it parses, else the LAST line that parses
    as a JSON object (a warning ahead of the result, or stderr mixed in, must not turn a good run into a failure)."""
    try:
        d = json.loads(text)
        if isinstance(d, dict): return d
    except Exception: pass
    for line in reversed(text.splitlines()):
        line = line.strip()
        if not line.startswith("{"): continue
        try: d = json.loads(line)
        except Exception: continue
        if isinstance(d, dict): return d
    return None


def mode_finish(qid):
    r = load(qid)
    if r is None: return 2
    if r.get("state") != "done": r["state"] = "done"; r["done"] = int(time.time()); save(qid, r)
    return 0


def mode_result():
    d = parse_result(sys.stdin.read())
    if d is None: print("unreadable\t-\t-"); return 1
    sid = d.get("session_id") or "-"
    dt = d.get("deferred_tool_use")
    # Parked = the result carries deferred_tool_use AND the hook has just recorded that call for this session. The real CLI (2.1.307)
    # says terminal_reason "tool_deferred" and has no stop_reason key (the first build expected stop_reason, and printed "the run
    # failed" on the first real run); so the shape is the deferred_tool_use object, not either reason key. A reason key
    # that is present must not name another ending.
    reasons = [d.get(k) for k in ("terminal_reason", "stop_reason") if d.get(k)]
    if isinstance(dt, dict) and dt.get("id") and all(r == "tool_deferred" for r in reasons):
        qid = qid_of(sid, dt["id"])
        if load(qid) is not None:
            print("parked\t%s\t%s" % (qid, sid))
            return 0
        print("error\t-\t%s" % sid)   # a deferral no record answers (the hook failed open): not parked, nothing is waiting
        print(d.get("result") or "")
        return 1
    print("%s\t-\t%s" % ("error" if d.get("is_error") else "done", sid))
    print(d.get("result") or "")
    return 0


def main():
    a = sys.argv[1:]
    m = a[0] if a else ""
    if m == "hook":
        try: mode_hook()
        except Exception: pass   # fail open: no output = the normal flow, which grants nothing a background run did not already have
        return 0
    if m == "answer": return mode_answer(a[1:])
    if m == "show" and len(a) == 2: return mode_show(a[1])
    if m == "set" and len(a) >= 4 and len(a) % 2 == 0: return mode_set(*a[1:])
    if m == "text" and len(a) == 2: return mode_text(a[1])
    if m == "finish" and len(a) == 2: return mode_finish(a[1])
    if m == "list": return mode_list()
    if m == "sweep": return mode_sweep()
    if m == "result": return mode_result()
    if m == "settings-json":
        tools = "|".join(defer_tools()) or "AskUserQuestion"
        print(json.dumps({"hooks": {"PreToolUse": [{"matcher": tools, "hooks": [{"type": "command", "command": "%s hook ask" % shlex.quote(os.environ.get("SALA_BIN") or "salamander")}]}]}}))
        return 0
    if m == "host-json":
        print(json.dumps({"mcpServers": {"salahost": {"command": sys.executable or "python3", "args": ["-I", "-S", os.path.join(os.path.dirname(os.path.abspath(__file__)), "permission-host.py")]}}}))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


sys.exit(main())
