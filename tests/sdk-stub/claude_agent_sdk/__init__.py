"""A stand-in for claude-agent-sdk, for tests/sdklane.sh: the names contrib/sdk-pane/driver.py imports, with the shapes
of 0.2.165 (dataclass fields, ProcessError(message, exit_code, stderr), the client's connect / query / receive_messages /
interrupt / disconnect). connect() spawns the compiled fake claude (tests/fake-claude.c) the way the SDK spawns the CLI:
cli_path, `--resume <uuid>` (or `--session-id`), --model, --effort, --mcp-config <file>, --setting-sources=…, the extra
args (--name), and an environment of the caller's plus CLAUDE_CODE_ENTRYPOINT=sdk-py plus options.env — so the fake's
FAKE_LANE_LOG counts the key as the real CLI's environment would carry it, and proc_lane reads sdk. Its stdin is a pipe
(the fake sits at its prompt for ever), its screen goes nowhere: the driver is the screen.
Knobs (env, the tmux session's): FAKE_SDK=ok (default: every query is echoed) | credit (every query comes back as the
credit's refusal: an assistant message with error billing_error and an error result naming the credit balance) ·
FAKE_SDK_LOG=<file> (one JSON line per connect: the argv built, the NAMES of options.env, setting_sources, cli_path, the
mcp config, whether a permission callback was given — never a value of env) · FAKE_QUERY_LOG=<file> (one "<uuid> <prompt>"
line per query). The fake claude dying raises ProcessError from receive_messages, as the SDK does; disconnect() types
/exit into the fake (it leaves cleanly, dropping its registry row and socket), then kills what is left.
"""
import asyncio
import json
import os
import subprocess
import time
from dataclasses import dataclass, field
from types import SimpleNamespace
from typing import Any

__version__ = "0.0.0-stub"


@dataclass
class TextBlock:
    text: str


@dataclass
class ThinkingBlock:
    thinking: str
    signature: str


@dataclass
class ToolUseBlock:
    id: str
    name: str
    input: dict


@dataclass
class ToolResultBlock:
    tool_use_id: str
    content: Any = None
    is_error: bool | None = None


@dataclass
class UserMessage:
    content: Any
    uuid: str | None = None
    parent_tool_use_id: str | None = None
    tool_use_result: dict | None = None
    origin: dict | None = None


@dataclass
class AssistantMessage:
    content: list
    model: str
    parent_tool_use_id: str | None = None
    error: str | None = None
    usage: dict | None = None
    message_id: str | None = None
    stop_reason: str | None = None
    session_id: str | None = None
    uuid: str | None = None


@dataclass
class SystemMessage:
    subtype: str
    data: dict


@dataclass
class ResultMessage:
    subtype: str
    duration_ms: int
    duration_api_ms: int
    is_error: bool
    num_turns: int
    session_id: str
    stop_reason: str | None = None
    total_cost_usd: float | None = None
    usage: dict | None = None
    result: str | None = None
    structured_output: Any = None
    model_usage: dict | None = None


@dataclass
class PermissionResultAllow:
    behavior: str = "allow"
    updated_input: dict | None = None
    updated_permissions: list | None = None


@dataclass
class PermissionResultDeny:
    behavior: str = "deny"
    message: str = ""
    interrupt: bool = False


class ClaudeSDKError(Exception):
    pass


class CLIConnectionError(ClaudeSDKError):
    pass


class CLINotFoundError(CLIConnectionError):
    pass


class ProcessError(ClaudeSDKError):
    def __init__(self, message, exit_code=None, stderr=None):
        self.exit_code = exit_code
        self.stderr = stderr
        if exit_code is not None:
            message = f"{message} (exit code: {exit_code})"
        if stderr:
            message = f"{message}\nError output: {stderr}"
        super().__init__(message)


@dataclass
class ClaudeAgentOptions:
    allowed_tools: list = field(default_factory=list)
    system_prompt: Any = None
    mcp_servers: Any = field(default_factory=dict)
    permission_mode: str | None = None
    continue_conversation: bool = False
    resume: str | None = None
    max_turns: int | None = None
    model: str | None = None
    effort: str | None = None
    cwd: Any = None
    cli_path: Any = None
    settings: str | None = None
    env: dict = field(default_factory=dict)
    extra_args: dict = field(default_factory=dict)
    max_buffer_size: int | None = None
    stderr: Any = None
    can_use_tool: Any = None
    setting_sources: list | None = None
    session_id: str | None = None
    fork_session: bool = False
    strict_mcp_config: bool = False
    include_partial_messages: bool = False
    permission_prompt_tool_name: str | None = None


def _log(var, line):
    path = os.environ.get(var)
    if path:
        with open(path, "a", encoding="utf-8") as f:
            f.write(line + "\n")


class ClaudeSDKClient:
    def __init__(self, options=None, transport=None):
        self.options = options or ClaudeAgentOptions()
        self._proc = None
        self._q = None
        self._watch = None
        self._closing = False
        self._transport = SimpleNamespace(_process=None)

    def _sid(self):
        return self.options.resume or self.options.session_id or ""

    async def connect(self, prompt=None):
        o = self.options
        self._q = asyncio.Queue()
        cli = str(o.cli_path) if o.cli_path else "claude"
        cmd = [cli, "--output-format", "stream-json", "--verbose"]
        if o.resume:
            cmd += ["--resume", o.resume]
        elif o.session_id:
            cmd += ["--session-id", o.session_id]
        if o.model:
            cmd += ["--model", o.model]
        if o.effort:
            cmd += ["--effort", o.effort]
        if isinstance(o.mcp_servers, (str, os.PathLike)):
            cmd += ["--mcp-config", str(o.mcp_servers)]
        if o.setting_sources is not None:
            cmd.append("--setting-sources=" + ",".join(o.setting_sources))
        for k, v in (o.extra_args or {}).items():
            cmd += [f"--{k}"] + ([str(v)] if v is not None else [])
        env = {k: v for k, v in os.environ.items() if k != "CLAUDECODE"}
        env["CLAUDE_CODE_ENTRYPOINT"] = "sdk-py"
        env.update(o.env or {})
        env["CLAUDE_AGENT_SDK_VERSION"] = __version__
        _log("FAKE_SDK_LOG", json.dumps({"argv": cmd, "env_names": sorted(o.env or {}), "setting_sources": o.setting_sources,
                                        "cli_path": str(o.cli_path) if o.cli_path else None, "mcp": str(o.mcp_servers),
                                        "can_use_tool": o.can_use_tool is not None, "cwd": str(o.cwd) if o.cwd else None,
                                        "system_prompt": o.system_prompt}))
        try:
            self._proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                          env=env, cwd=str(o.cwd) if o.cwd else None)
        except OSError as e:
            raise CLINotFoundError(f"Claude Code not found: {cli}: {e}") from e
        self._transport._process = self._proc
        await asyncio.sleep(0.2)
        if self._proc.poll() is not None:
            raise ProcessError("Command failed", exit_code=self._proc.returncode, stderr="fake claude ended at once")
        await self._q.put(SystemMessage("init", {"claude_code_version": "9.9.9", "model": o.model or "fake-model", "tools": ["Bash", "Read"],
                                                 "mcp_servers": [], "session_id": self._sid()}))
        self._watch = asyncio.ensure_future(self._watch_proc())

    async def _watch_proc(self):
        while self._proc.poll() is None:
            await asyncio.sleep(0.2)
        await self._q.put(("__dead__", self._proc.returncode))

    async def receive_messages(self):
        if self._q is None:
            raise CLIConnectionError("Not connected. Call connect() first.")
        while True:
            m = await self._q.get()
            if isinstance(m, tuple) and m[0] == "__dead__":
                if self._closing:
                    return
                raise ProcessError("Command failed", exit_code=m[1], stderr="fake claude ended")
            yield m

    async def receive_response(self):
        async for m in self.receive_messages():
            yield m
            if isinstance(m, ResultMessage):
                return

    async def query(self, prompt, session_id="default"):
        if self._q is None:
            raise CLIConnectionError("Not connected. Call connect() first.")
        sid = self._sid()
        _log("FAKE_QUERY_LOG", f"{sid} {prompt}")
        await asyncio.sleep(0.1)
        if os.environ.get("FAKE_SDK", "ok") == "credit":
            text = "Your credit balance is too low to access the Anthropic API. Please go to Plans & Billing to upgrade or purchase credits."
            await self._q.put(AssistantMessage([TextBlock(text)], "<synthetic>", error="billing_error", session_id=sid))
            await self._q.put(ResultMessage("success", 120, 100, True, 1, sid, result=text))
            return
        await self._q.put(AssistantMessage([TextBlock("echo: " + prompt)], "fake-model", session_id=sid))
        await self._q.put(ResultMessage("success", 120, 100, False, 1, sid, total_cost_usd=0.0001, result="echo: " + prompt))

    async def interrupt(self):
        pass

    async def disconnect(self):
        self._closing = True
        p = self._proc
        if p is not None and p.poll() is None:
            try:
                p.stdin.write(b"/exit\n")
                p.stdin.flush()
            except OSError:
                pass
            for _ in range(20):
                if p.poll() is not None:
                    break
                await asyncio.sleep(0.1)
            if p.poll() is None:
                p.kill()
        if self._watch:
            self._watch.cancel()
        if self._q is not None:
            await self._q.put(("__dead__", p.returncode if p else 0))

    async def __aenter__(self):
        await self.connect()
        return self

    async def __aexit__(self, *exc):
        await self.disconnect()
        return False


async def query(prompt, options=None):
    client = ClaudeSDKClient(options)
    await client.connect()
    await client.query(prompt)
    async for m in client.receive_response():
        yield m
    await client.disconnect()
