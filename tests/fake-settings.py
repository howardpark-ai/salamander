#!/usr/bin/env python3
"""What Claude Code does to a lane's settings.json when /model or /effort is typed (tests/fake-claude.c calls it, FAKE_SETTINGS_PY;
tests/modelinplace.sh, measured on 2.1.310): the command is saved as the lane's DEFAULT, the top-level `model`, and
`modelSettings.<model id>.effortLevel`. Written the way the CLI writes the file: two-space indent, a trailing newline, the other
keys as they are.

  fake-settings.py <config dir> model <value>
  fake-settings.py <config dir> effort <model> <level>
"""
import json, os, sys

d, what = sys.argv[1], sys.argv[2]
path = os.path.join(d, "settings.json")
try:
    with open(path, encoding="utf-8") as f: cur = json.load(f)
except FileNotFoundError:
    cur = {}
if what == "model":
    cur["model"] = sys.argv[3]
elif what == "effort":
    cur.setdefault("modelSettings", {}).setdefault(sys.argv[3], {})["effortLevel"] = sys.argv[4]
os.makedirs(d, exist_ok=True)
with open(path, "w", encoding="utf-8") as f:
    f.write(json.dumps(cur, indent=2, ensure_ascii=False) + "\n")
