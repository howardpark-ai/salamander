"""sdk_run.py — one briefing turn through the Claude Agent SDK on an API key's prepaid credit.
The credit pays for direct Messages API and Agent SDK calls on the key and refuses anything sent as Claude Code
(`claude -p` with the key: "Your credit balance is too low"), so this is the real SDK, never a CLI run dressed up as one.

THE CREDIT RECORD. The callers try this runner while the shared record (lib/api_credit.py:
${XDG_STATE_HOME:-~/.local/state}/api-credit/state.json) holds no refusal less than 6 hours old. This file keeps the record:
a turn that ended with a non-error result removes it (the key worked); a refusal with "credit balance" in the result, the
SDK exception or the CLI's stderr writes it ({"refused_at", "by": --by, "detail"}) before the runner exits 1, and the caller
falls back to `claude -p` on its login. Nothing else touches the record: any other failure leaves it as it was.

Run by lib.sh's run_claude and release-watch.sh's relay, never by hand on a schedule:
    uv run --quiet --no-project --with claude-agent-sdk==<pin> python -I sdk_run.py \
        --model sonnet --allowed-tools a,b [--mcp-config <file> --mcp-server mcp-portal] [--output stream-json|text] < prompt
Inputs: the prompt on stdin, the model, the allowed tools (the same list as the `claude -p` call), and the MCP config file
whose named servers are loaded (strict: nothing else; no claude.ai connector exists on the key anyway; no file, no server). The key and
the workspace id are read here from --key-file / --workspace-file and go only into the env of the CLI process the SDK
spawns (ANTHROPIC_API_KEY, ANTHROPIC_CUSTOM_HEADERS): never argv, never printed, never exported by the shell. That
process runs on the default ~/.claude config, where the portal's OAuth token lives; no settings files, hooks or CLAUDE.md
are loaded (setting_sources=[]), and the system prompt is Claude Code's own, as with `claude -p`. The one settings input
is --settings, the JSON lib.sh builds for the read guard hook, handed to the CLI's own --settings flag.
Output: --output stream-json (default) prints one JSON line per message in the shape of `claude -p --output-format
stream-json` (system / assistant with tool_use blocks / user / result), which lib.sh's parsers read unchanged; --output
text prints only the final result text. Exit 0 when the turn ended with a non-error result, 1 otherwise (an error result,
no result, or an SDK exception, whose text goes to stderr: the caller greps both for "credit balance").
"""
import argparse
import asyncio
import dataclasses
import importlib.util
import json
import os
import sys

# the shared credit record, loaded by path: this runs under `python -I`, which puts no sibling directory on sys.path
_spec = importlib.util.spec_from_file_location("api_credit", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib", "api_credit.py"))
api_credit = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(api_credit)

BLOCK_TYPES = {"TextBlock": "text", "ToolUseBlock": "tool_use", "ToolResultBlock": "tool_result", "ThinkingBlock": "thinking"}


def plain(x):
    return dataclasses.asdict(x) if dataclasses.is_dataclass(x) and not isinstance(x, type) else x


def block(b):
    d = plain(b)
    d = dict(d) if isinstance(d, dict) else {"value": str(d)}
    d["type"] = BLOCK_TYPES.get(type(b).__name__, type(b).__name__)
    return d


def record(m):
    """One SDK message as the stream-json line `claude -p` would have printed for it."""
    n = type(m).__name__
    if n == "AssistantMessage":
        return {"type": "assistant", "error": m.error, "session_id": m.session_id,
                "message": {"model": m.model, "content": [block(b) for b in m.content],
                            "stop_reason": m.stop_reason, "usage": m.usage}}
    if n == "UserMessage":
        content = m.content if isinstance(m.content, str) else [block(b) for b in m.content]
        return {"type": "user", "message": {"role": "user", "content": content}}
    if n == "SystemMessage":
        return {**(m.data or {}), "type": "system", "subtype": m.subtype}
    if n == "ResultMessage":
        return {**plain(m), "type": "result"}
    d = plain(m)
    return {**(d if isinstance(d, dict) else {"value": str(d)}), "type": n}


def read1(path):
    with open(path, encoding="utf-8") as f:
        return f.read().strip()


async def turn(a, prompt):
    from claude_agent_sdk import ClaudeAgentOptions, query
    mcp = {}
    if a.mcp_config:   # none (release-watch's relay): no MCP server at all
        servers = json.load(open(a.mcp_config, encoding="utf-8"))["mcpServers"]
        mcp = {name: servers[name] for name in a.mcp_server}   # KeyError: a named server missing from the file
    env = {"ANTHROPIC_API_KEY": read1(a.key_file)}
    if a.workspace_file:
        env["ANTHROPIC_CUSTOM_HEADERS"] = "anthropic-workspace-id: " + read1(a.workspace_file)
    opts = ClaudeAgentOptions(
        model=a.model, allowed_tools=[t for t in a.allowed_tools.split(",") if t],
        mcp_servers=mcp, strict_mcp_config=True, setting_sources=[], settings=a.settings or None,
        system_prompt={"type": "preset", "preset": "claude_code"}, cwd=a.cwd, env=env)
    result = None
    async for m in query(prompt=prompt, options=opts):
        r = record(m)
        if r["type"] == "result":
            result = r
        if r["type"] == "assistant" and r.get("error") == "billing_error":
            a.refusal = a.refusal or " ".join(str(b.get("text", "")) for b in r["message"]["content"] if isinstance(b, dict)) or "billing_error"
        if a.output == "stream-json":
            print(json.dumps(r, ensure_ascii=False, default=str), flush=True)
    if a.output == "text" and result is not None:
        print(result.get("result") or "")
    if result is None:
        print("sdk_run: the turn ended without a result", file=sys.stderr)
        return 1
    if result.get("is_error"):
        text = str(result.get('result') or result.get('errors'))
        print(f"sdk_run: error result ({result.get('subtype')}): {text[:500]}", file=sys.stderr)
        if api_credit.is_refusal(text):
            a.refusal = a.refusal or text
        return 1
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--model", required=True)
    p.add_argument("--allowed-tools", default="")
    p.add_argument("--mcp-config", default="")
    p.add_argument("--mcp-server", action="append", default=[], help="a server in --mcp-config to load (repeatable)")
    p.add_argument("--settings", default="", help="a settings JSON string or file for the CLI's --settings (the read guard hook)")
    p.add_argument("--key-file", default=os.path.expanduser("~/.config/anthropic/api-key"))
    p.add_argument("--workspace-file", default=os.path.expanduser("~/.config/anthropic/workspace-id"))
    p.add_argument("--cwd", default=os.path.expanduser("~"))
    p.add_argument("--output", choices=["stream-json", "text"], default="stream-json")
    p.add_argument("--by", default="sdk_run", help="the job's name, written into the credit record when the key's credit refuses")
    a = p.parse_args()
    a.refusal = ""   # the refusal text seen on the way, written to the credit record on the way out
    prompt = sys.stdin.read()
    try:
        rc = asyncio.run(turn(a, prompt))
    except Exception as e:   # ProcessError carries the CLI's stderr: where a "credit balance" refusal shows up
        print(f"sdk_run: {type(e).__name__}: {e}", file=sys.stderr)
        seen = [str(e)]
        for attr in ("stderr", "exit_code"):
            if getattr(e, attr, None):
                print(f"sdk_run: {attr}: {getattr(e, attr)}", file=sys.stderr)
                seen.append(str(getattr(e, attr)))
        if api_credit.is_refusal(" ".join(seen)):
            a.refusal = a.refusal or " ".join(seen)
        rc = 1
    try:
        if rc == 0:
            api_credit.record_success()
        elif a.refusal:
            api_credit.record_refusal(a.by, a.refusal)
    except OSError as e:   # the record is a courtesy to the other jobs: the run's own fallback does not wait on it
        print(f"sdk_run: could not update the credit record: {e}", file=sys.stderr)
    return rc


if __name__ == "__main__":
    sys.exit(main())
