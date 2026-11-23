#!/usr/bin/env python3
"""stackshot_form.py: run stackshot's client for one of the New session form's calls, with a pass instead of the machine token when sala has one.

    python3 stackshot_form.py run <client.py> <client args...>

Gets a pass (lib/stackshot_key.py: the cached one, else a signed claim traded for one) and replaces itself with `python3 <client.py> <client args...>`, with the environment
variable STACKSHOT_CLIENT_PASS set to the pass for that child only. stackshot's client.py reads that variable in place of its machine-token file (that is stackshot's change; until
it is live the variable is ignored and the client uses the machine token, which works exactly as before). Standard input, standard output, standard error and the exit code are the
client's own: nothing is read, printed or caught here, and the process IS the client after the exec.

Any failure to get a pass (no key made yet, the key still waiting for approval, the server not reached, the `cryptography` package missing, an error answer) runs the client plainly with the
machine token, as it ran before this wrapper; at most one line per five minutes in $SALA_LOG_DIR/salamander-stackshot-key.log says why. SALA_STACKSHOT_PASS=off skips the pass step.
The wrapper is for the form's calls only (`post project-agent`, `post project-agent-rename`, `post project-agent-retire`); every other client call keeps the machine token and is not run
through it. The pass is never printed, logged or put in an argv."""
from __future__ import annotations

import os
import sys


def main(argv: list[str]) -> int:
    if len(argv) < 3 or argv[1] != "run":
        print("usage: stackshot_form.py run <client.py> <client args...>", file=sys.stderr)
        return 2
    env = dict(os.environ)
    env.pop("STACKSHOT_CLIENT_PASS", None)      # a value from outside is never a pass of ours
    pw = None
    try:
        import stackshot_key      # beside this file: python puts the script's folder first on the path
        pw = stackshot_key.get_pass()
    except Exception:       # nothing about a pass may stop the call
        pw = None
    if pw:
        env["STACKSHOT_CLIENT_PASS"] = pw
    try:
        os.execvpe("python3", ["python3", *argv[2:]], env)
    except OSError as e:
        print("stackshot_form.py: cannot run python3 (%s)" % type(e).__name__, file=sys.stderr)
        return 127
    return 127


if __name__ == "__main__":
    sys.exit(main(sys.argv))
