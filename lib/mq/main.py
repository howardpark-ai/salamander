#!/usr/bin/env python3
"""lib/mq/main.py — entry of `salamander mq` (lib/mq.sh runs it as `python3 -I`, which keeps this folder off sys.path, so it is added here). docs/mq.md."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

if sys.version_info < (3, 11):
    print("salamander mq: needs python3 3.11 or newer (tomllib); this is %d.%d" % sys.version_info[:2], file=sys.stderr)
    sys.exit(2)

import mq_cli  # noqa: E402

if __name__ == "__main__":
    sys.exit(mq_cli.main(sys.argv[1:]))
