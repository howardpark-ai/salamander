#!/usr/bin/env python3
"""tests/stackshotkey_client.py: a stand-in for stackshot's client.py for tests/stackshotkey.sh. It prints what it was asked (its arguments, and the number of lines it read from
standard input), prints one line on standard error, and exits with $FAKE_RC (default 0): the same bytes whether it was started through lib/stackshot_form.py or directly.
It appends one JSON line to $FAKE_OUT saying which credential it would use: `pass` when STACKSHOT_CLIENT_PASS is set (with the first 12 hex characters of the value's SHA-256,
never the value) or `machine-token`, and its arguments. It never prints the variable's value."""
import hashlib
import json
import os
import sys

pw = os.environ.get("STACKSHOT_CLIENT_PASS")
stdin_lines = len(sys.stdin.read().splitlines()) if not sys.stdin.isatty() else 0
rec = {"credential": "pass" if pw else "machine-token", "argv": sys.argv[1:], "stdin_lines": stdin_lines}
if pw:
    rec["pass_sha12"] = hashlib.sha256(pw.encode()).hexdigest()[:12]
out = os.environ.get("FAKE_OUT")
if out:
    with open(out, "a", encoding="utf-8") as f:
        f.write(json.dumps(rec) + "\n")
print("client asked: " + " ".join(sys.argv[1:]) + " (stdin lines: %d)" % stdin_lines)
print("client note", file=sys.stderr)
sys.exit(int(os.environ.get("FAKE_RC", "0")))
