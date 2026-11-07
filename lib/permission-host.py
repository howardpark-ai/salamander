#!/usr/bin/env python3
"""lib/permission-host.py — a stdio MCP server whose one tool, `approve`, DENIES every permission request it is asked about.

Why it exists (verified on Claude Code 2.1.307, Thu Oct 22nd 2026): a `claude -p` run offers AskUserQuestion
only when it has a permission host to receive the prompt; without one the tool is not in the model's tool list and the model
answers in prose. `salamander question run` starts a background run with `--permission-prompt-tool mcp__salahost__approve` so the
tool is offered, and the PreToolUse hook (`salamander hook ask`) defers the call before this server is ever consulted. Whatever
else would have prompted reaches this server and is denied, which is what a `-p` run does with no host at all: the host grants
nothing, ever. Standard library only; run as `python3 -I -S permission-host.py`."""
import json, sys


def send(o):
    sys.stdout.write(json.dumps(o) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    try:
        m = json.loads(line)
    except Exception:
        continue
    if not isinstance(m, dict):
        continue
    i, meth = m.get("id"), m.get("method")
    if meth == "initialize":
        pv = (m.get("params") or {}).get("protocolVersion", "2024-11-05")
        send({"jsonrpc": "2.0", "id": i, "result": {"protocolVersion": pv, "capabilities": {"tools": {}}, "serverInfo": {"name": "salahost", "version": "1"}}})
    elif meth == "tools/list":
        send({"jsonrpc": "2.0", "id": i, "result": {"tools": [{"name": "approve", "description": "sala's permission host: denies every request (nobody answers a background run)",
              "inputSchema": {"type": "object", "properties": {"tool_name": {"type": "string"}, "input": {"type": "object"}, "tool_use_id": {"type": "string"}}, "required": ["tool_name", "input"]}}]}})
    elif meth == "tools/call":
        send({"jsonrpc": "2.0", "id": i, "result": {"content": [{"type": "text", "text": json.dumps({"behavior": "deny", "message": "A background run: nobody is there to approve this. Ask for it in your answer instead of trying again."})}]}})
    elif i is not None:
        send({"jsonrpc": "2.0", "id": i, "result": {}})
