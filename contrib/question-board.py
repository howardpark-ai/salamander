#!/usr/bin/env python3
"""contrib/question-board.py — sala's two parked-question seams, filled with stackshot's shell verbs (Thu Oct 22nd 2026).
Standard library only; run as `python3 -I -S question-board.py file|answer` by the two wrappers beside it
(question-board-file.sh, question-board-answer.sh), which `lib/question.sh` runs as SALA_QUESTION_FILE_CMD / SALA_QUESTION_ANSWER_CMD
when those are unset and the client exists (docs/stuck-question-recovery.md).

  file     the question text on stdin; SALA_QUESTION_ID / _SESSION / _LABEL in the environment. Files it as a needs=decision item with
           `client.py post question` and prints the item id as the first word of the first line. Exit 0 filed · 1 refused or not
           reached (sala keeps the question retryable: `sala question sweep` or `sala question file QID` tries again) · 2 misused.
  answer   SALA_QUESTION_ID and SALA_QUESTION_ITEM in the environment. Reads `client.py get answer <item>` and prints the owner's answer
           only when it is a DECISION (never a comment) and fits the parked call; otherwise nothing and exit 1 ("not yet").

Settings: SALA_STACKSHOT_CLIENT (default stackshot/fleet/client.py under SALA_STACKSHOT_DIR, client.py there on a checkout from before stackshot's package; ~/stackshot when that is unset, no client when it is empty), SALA_QUESTION_PROJECT (the project page the item belongs to; no default, the filer refuses with none), SALA_QUESTION_SCOPE (the subject bracket; lib/question.sh sets it from SALA_DEFAULT_SCOPE).
Needs SALA_STATE_DIR in the environment (lib/question.sh sets it) to find the parked record; without it the XDG default is used.

What the board takes, and how the item is shaped for it (checked against stackshot's server.py and render.py):
  - the text on stdin: at most 5 non-blank lines and 8000 characters, else the client refuses it. A longer text is cut here, ending
    with "(cut; see sala question show <id>)", so the client never refuses for length.
  - the ask: one line of at most 240 characters, "Decide: … · Recommend: … · Stakes: … · By: …", the Decide part with no " · " and no ";"
    (the server reads either as several decisions): the question is made safe for that and trimmed to fit.
  - options: 2 to 6 of "label=line" (label at most 40 characters, line at most 160, one line each, no "=" in a label), exactly one flagged
    recommended. One AskUserQuestion question that is not a multi-select gets its options as buttons, and the label the owner picks is what
    `sala resume-answer` takes. The flagged one is the option whose label says "(Recommended)", else the first (the server insists on one;
    the ask still says "Recommend: none, your call" when the run named none). A listed tool other than AskUserQuestion (SALA_DEFER_TOOLS)
    gets Yes / No, No flagged (the safe one). Several questions, a multi-select, or labels the board cannot take: no buttons, and the
    item says to answer in words, which `answer` checks against the call before it prints anything."""
import json, os, re, subprocess, sys

MAX_LINES, MAX_CHARS, LINE_CAP = 5, 8000, 1500
ASK_MAX, SUBJECT_MAX, LABEL_MAX, OPT_LINE_MAX, SENDER_MAX = 240, 80, 40, 160, 80
SUBJECT_LABEL_MAX = 30   # the label in the subject, so a long label leaves the question room inside SUBJECT_MAX
ASK_STAKES, ASK_BY = "a background run is parked until you answer", "any time"
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def one_line(s):
    return " ".join(str(s or "").split())


def trim(s, n):
    s = one_line(s)
    return s if len(s) <= n else s[: max(n - 1, 0)].rstrip() + "…"


def state_dir():
    return os.environ.get("SALA_STATE_DIR") or os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state"), "salamander")


def load_record(qid):
    try:
        with open(os.path.join(state_dir(), "questions", qid, "record.json")) as f:
            r = json.load(f)
        return r if isinstance(r, dict) else {}
    except Exception:
        return {}


def stackshot_client_in(d):
    """The client under stackshot's checkout <d>: stackshot/fleet/client.py, or client.py in the root of a checkout from before the
    package (stackshot leaves a forwarder there until Sun Nov 22nd 2026; lib/stackshot-path.sh is the shell side of this)."""
    new = os.path.join(d, "stackshot", "fleet", "client.py")
    old = os.path.join(d, "client.py")
    return old if os.path.isfile(old) and not os.path.isfile(new) else new

def client_path():
    if os.environ.get("SALA_STACKSHOT_CLIENT"):   # a setting that names the file wins over the probe
        return os.environ["SALA_STACKSHOT_CLIENT"]
    d = os.environ.get("SALA_STACKSHOT_DIR")   # unset: ~/stackshot; set empty: this box has no stackshot
    if d is None:
        d = os.path.join(os.path.expanduser("~"), "stackshot")
    return stackshot_client_in(d) if d else ""


def run_client(args, stdin_text=None, timeout=50):
    c = client_path()
    if not c or not os.path.isfile(c):
        print("question-board: no stackshot client at %s (SALA_STACKSHOT_CLIENT)" % c, file=sys.stderr)
        return None
    cmd = ([c] if os.access(c, os.X_OK) else [sys.executable, c]) + args
    try:
        return subprocess.run(cmd, input=stdin_text, capture_output=True, text=True, timeout=timeout) if stdin_text is not None else \
            subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout)
    except Exception as e:
        print("question-board: the client did not run (%s)" % type(e).__name__, file=sys.stderr)
        return None


# ---- file -------------------------------------------------------------------------------------------------------------------------

def ask_safe(s):
    """A question made safe to sit in the ask's Decide part: one line, no " · " or ";" (read as several decisions), no ask labels."""
    s = one_line(s).replace("·", "-").replace(";", ",")
    return re.sub(r"\b(Decide|Recommend|Stakes|By):", r"\1 -", s)


def build_ask(question, more):
    tail = " (+%d more, see the item, answer one line each as '1: label')" % more if more else ""
    fixed = "Decide:  · Recommend: none, your call · Stakes: %s · By: %s" % (ASK_STAKES, ASK_BY)
    room = ASK_MAX - len(fixed) - len(tail)
    return "Decide: %s%s · Recommend: none, your call · Stakes: %s · By: %s" % (trim(ask_safe(question), room), tail, ASK_STAKES, ASK_BY)


def fit_text(body, extras, qid):
    """The question text as lines the client takes: at most MAX_LINES non-blank lines (extras included) and MAX_CHARS characters; a longer
    text keeps its head and ends with a cut line. Never longer than the client allows, so it never refuses for length."""
    allowed = MAX_LINES - len(extras)
    cut = len(body) > allowed or any(len(l) > LINE_CAP for l in body[:allowed])
    kept = body[: allowed - 1] if cut else list(body)
    kept = [l if len(l) <= LINE_CAP else l[: LINE_CAP - 1] + "…" for l in kept]
    if cut:
        kept.append("(cut; see sala question show %s)" % qid)
    return kept + extras


def first_question(rec, lines):
    """→ (the first question as sala printed it, how many more questions there are, the record's questions). The words come from the
    text on stdin, which sala has already masked of secrets, never from the record, which has not been."""
    qs = rec.get("tool_input", {}).get("questions") if rec.get("tool") == "AskUserQuestion" and isinstance(rec.get("tool_input"), dict) else None
    qs = [q for q in qs if isinstance(q, dict) and isinstance(q.get("question"), str)] if isinstance(qs, list) else []
    first = re.sub(r"^\d+\.\s+", "", lines[0] if lines else "a parked question") if len(qs) > 1 else (lines[0] if lines else "a parked question")
    return re.sub(r"\s{2}\[[^\]]*\]$", "", first), max(len(qs) - 1, 0), qs


def board_options(rec, qs):
    """→ ([(label, line)], index of the recommended one), or ([], 0) when the board cannot take the options as buttons."""
    if rec.get("tool") and rec.get("tool") != "AskUserQuestion":
        return [("Yes", "Allow this exact call."), ("No", "Deny it; nothing is granted.")], 1
    if len(qs) != 1 or qs[0].get("multiSelect"):
        return [], 0
    raw = [o for o in (qs[0].get("options") or []) if isinstance(o, dict) and isinstance(o.get("label"), str)]
    out = []
    for o in raw:
        label = o["label"].strip()
        if not label or len(label) > LABEL_MAX or "=" in label or label != one_line(label):   # the board keeps one-line labels, and the answer must map back
            return [], 0
        out.append((label, trim(o.get("description") or "", OPT_LINE_MAX) or "Pick “%s”." % label))
    if not 2 <= len(out) <= 6 or len({l.lower() for l, _ in out}) != len(out):
        return [], 0
    rec_i = next((i for i, (l, _) in enumerate(out) if "(recommended)" in l.lower()), 0)
    return out, rec_i


def subject_prefix():
    """The scope bracket a board subject opens with ("[alpha] "): stackshot refuses a subject that starts with none of its configured
    prefixes. It is SALA_QUESTION_SCOPE (lib/question.sh: SALA_DEFAULT_SCOPE, else the first of SALA_SCOPES); with none set, no prefix."""
    words = os.environ.get("SALA_QUESTION_SCOPE", "").split()   # the first word; leading blanks do not make it empty
    scope = re.sub(r"[^A-Za-z0-9._-]", "", words[0] if words else "")
    return "[%s] " % scope if scope else ""


def mode_file():
    qid = os.environ.get("SALA_QUESTION_ID", "").strip()
    if not qid:
        print("question-board file: SALA_QUESTION_ID is not set", file=sys.stderr)
        return 2
    lines = [l.rstrip() for l in sys.stdin.read().splitlines() if l.strip()]
    if not lines:
        print("question-board file: the question text on stdin is empty", file=sys.stderr)
        return 2
    project = os.environ.get("SALA_QUESTION_PROJECT", "").strip()
    if not project:
        print("question-board file: SALA_QUESTION_PROJECT is not set", file=sys.stderr)
        return 2
    rec = load_record(qid)
    question, more, qs = first_question(rec, lines)
    opts, rec_i = board_options(rec, qs)
    label = one_line(os.environ.get("SALA_QUESTION_LABEL") or rec.get("label") or "") or "a background run"
    sender = trim(label, SENDER_MAX) if label != "a background run" else trim(os.environ.get("SALA_QUESTION_SESSION") or "sala", SENDER_MAX)
    extras = [] if opts else ["Answer in words on the item: an option's label or number%s." % (", one line per question as '1: label'" if more else "")]
    text = "\n".join(fit_text([re.sub(r"(?i)\b(resolved|done):", r"\1 -", l) for l in lines], extras, qid))
    args = ["post", "question", "--project", project,
            "--subject", trim("%s%s: %s" % (subject_prefix(), trim(label, SUBJECT_LABEL_MAX), question), SUBJECT_MAX), "--request-id", qid,
            "--ask", build_ask(question, more), "--sender", sender]
    for l, line in opts:
        args += ["--option", "%s=%s" % (l, line)]
    if opts:
        args += ["--recommended", opts[rec_i][0]]
    r = run_client(args, text, 20)   # under the hook's 25 s: a slow board leaves it to the sweep, and the request id makes the retry safe
    if r is None:
        return 1
    item = (r.stdout.split() or [""])[0]
    if r.returncode != 0 or not item:
        print("question-board file: the board did not take it (client exit %s): %s" % (r.returncode, one_line(r.stderr)[:600]), file=sys.stderr)
        return 1
    print(item)
    return 0


# ---- answer -----------------------------------------------------------------------------------------------------------------------

def fits(qid, words):
    """True when sala would take these words for the parked call (lib/question.py `answer --check`: nothing stored)."""
    env = dict(os.environ, SALA_STATE_DIR=state_dir())
    r = subprocess.run([sys.executable, "-I", "-S", os.path.join(ROOT, "lib", "question.py"), "answer", qid, "--check", words],
                       capture_output=True, text=True, env=env, stdin=subprocess.DEVNULL)
    if r.returncode != 0:
        print("question-board answer: %s" % one_line(r.stderr)[:400], file=sys.stderr)
    return r.returncode == 0


def mode_answer():
    qid, item = os.environ.get("SALA_QUESTION_ID", "").strip(), os.environ.get("SALA_QUESTION_ITEM", "").strip()
    if not qid or not item or item == "-":
        return 1   # not filed (yet): nothing to read
    r = run_client(["get", "answer", item], None, 25)
    if r is None or r.returncode != 0:
        if r is not None:
            print("question-board answer: client exit %s: %s" % (r.returncode, one_line(r.stderr)[:300]), file=sys.stderr)
        return 1
    line = r.stdout.strip("\n")
    if not line.strip():
        return 1   # he has not answered
    f = (line.split("\t") + ["", "", "", ""])[:4]
    kind, label, text = f[0].strip(), f[1].strip(), f[2].strip()
    if kind != "decision":
        return 1   # a comment is never an answer
    cands = [c for c in (label, text) if c]
    if text and " / " in text:   # the client writes a multi-line answer on one line with " / " between the lines
        cands.append("\n".join(p.strip() for p in text.split(" / ")))
    for c in cands:
        if fits(qid, c):
            print(c)
            return 0
    print("question-board answer: his decision on %s (%s) does not fit the parked call, so it is not used; answer with `sala resume-answer %s --answer …`" % (item, one_line(" | ".join(cands))[:200], qid), file=sys.stderr)
    return 1


if __name__ == "__main__":
    m = sys.argv[1] if len(sys.argv) > 1 else ""
    sys.exit(mode_file() if m == "file" else mode_answer() if m == "answer" else (print(__doc__, file=sys.stderr) or 2))
