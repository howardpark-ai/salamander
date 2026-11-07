"""api_credit.py — the shared "does the API key still have credit?" record (Sun Nov 1st 2026).

There is no API to read the credit balance, so the refusal itself is the signal. A job that may spend the Anthropic API key's
credit (sala's briefings, the sdk lane, the owner's other tools (a write-up check, a librarian)) asks this record before it uses the key, and
writes it when the key's call comes back "credit balance is too low":

    state file   ${XDG_STATE_HOME:-~/.local/state}/api-credit/state.json     (directory mode 700, file mode 600)
    content      {"refused_at": <epoch seconds>, "by": "<job name>", "detail": "<first 200 chars of the refusal>"}
    absent file  no known refusal: use the key.

THE RULE. Key configured, and no refused_at within the last API_CREDIT_RETRY_S seconds (default 21600, 6 hours): use the key.
Otherwise go straight to the subscription lane (Ultra, subscription-1) without trying the key. A refusal whose text holds
"credit balance" (any case) writes the file (a temp file in the same directory, then rename) and the run falls back; a
successful key call removes the file. So the key is tried again six hours after a refusal, and a top-up is found without anyone
telling sala.

Used as a module (sdk_run.py and contrib/sdk-pane/driver.py load it by path: they run under `python -I`, which puts no sibling
directory on sys.path) and as a command, which the shell side calls (lib/api-credit.sh):

    api_credit.py check [--now EPOCH]          exit 0: use the key; exit 1: a refusal is fresh, use the subscription
    api_credit.py refuse <by> [<detail>]       record a refusal now (the detail is cut to 200 characters)
    api_credit.py clear                        remove the record (a successful key call)
    api_credit.py show                         print the record, or "no known refusal"

Stdlib only. API_CREDIT_RETRY_S and XDG_STATE_HOME are read from the environment at every call.
"""
import json
import os
import re
import sys
import tempfile
import time

DEFAULT_RETRY_S = 21600
DETAIL_MAX = 200
REFUSAL_RE = re.compile(r"credit balance", re.I)
USAGE = "usage: api_credit.py check [--now EPOCH] | refuse <by> [<detail>] | clear | show"


def state_dir():
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(base, "api-credit")


def state_path():
    return os.path.join(state_dir(), "state.json")


def retry_s():
    try:
        n = int(os.environ.get("API_CREDIT_RETRY_S", ""))
    except ValueError:
        return DEFAULT_RETRY_S
    return n if n > 0 else DEFAULT_RETRY_S


def is_refusal(text):
    """True when text (a refusal, an stderr line, an error result) says the credit is used up."""
    return bool(text) and bool(REFUSAL_RE.search(str(text)))


def read():
    """The record as a dict with an int refused_at, or None (absent, unreadable, not a record: no known refusal)."""
    try:
        with open(state_path(), encoding="utf-8") as f:
            d = json.load(f)
        at = d["refused_at"]
        if isinstance(at, bool) or not isinstance(at, (int, float)):
            return None
        d["refused_at"] = int(at)
        return d
    except (OSError, ValueError, KeyError, TypeError):
        return None


def use_key(now=None):
    """True when the key may be used: no record, or its refused_at is retry_s() or more away from now (either side: a clock
    set wrong never blocks the key for longer than the retry time)."""
    d = read()
    if d is None:
        return True
    now = time.time() if now is None else now
    return abs(now - d["refused_at"]) >= retry_s()


def record_refusal(by, detail="", now=None):
    """Write the record atomically (a temp file in the same directory, then rename). Returns the record."""
    rec = {"refused_at": int(time.time() if now is None else now), "by": str(by),
           "detail": " ".join(str(detail).split())[:DETAIL_MAX]}
    d = state_dir()
    os.makedirs(os.path.dirname(d), exist_ok=True)
    try:
        os.mkdir(d, 0o700)
    except FileExistsError:
        pass
    fd, tmp = tempfile.mkstemp(prefix=".state-", suffix=".tmp", dir=d)   # mkstemp: mode 600
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(rec, f, ensure_ascii=False)
            f.write("\n")
        os.replace(tmp, state_path())
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return rec


def record_success():
    """A key call worked: remove the record if there is one."""
    try:
        os.unlink(state_path())
    except OSError:
        pass


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "check":
        now = float(argv[3]) if len(argv) > 3 and argv[2] == "--now" else None
        return 0 if use_key(now) else 1
    if cmd == "refuse" and len(argv) > 2:
        record_refusal(argv[2], argv[3] if len(argv) > 3 else "")
        return 0
    if cmd == "clear":
        record_success()
        return 0
    if cmd == "show":
        d = read()
        print(json.dumps(d, ensure_ascii=False) if d else "no known refusal")
        return 0
    print(USAGE, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
