"""driver.py — the screen of an sdk-lane pane (Wed Oct 14th 2026; lib/sdk-pane.sh runs it, never a hand):

    uv run --quiet --no-project --with claude-agent-sdk==<pin> python -I driver.py \
        --resume <uuid> | --new [<uuid>] [--name <session>]  [--session <tmux session>] [--model M] [--effort E] \
        --key-file F [--workspace-file W] [--mcp-config M] [--cli <claude launcher>] [--setting-sources user,project,local]

The Agent SDK (ClaudeSDKClient) spawns the CLI itself, marked as the SDK's (CLAUDE_CODE_ENTRYPOINT=sdk-py, set by the SDK —
this file never sets it), on the conversation given, and the credit that refuses Claude Code pays for its turns. The key and
the workspace id are read here from their files and go only into that CLI's environment (ANTHROPIC_API_KEY,
ANTHROPIC_CUSTOM_HEADERS): never argv, never printed, never exported by a shell. The CLI is sala's own launcher (--cli), so
the version it reports is the fleet's; it loads the user settings (hooks → sala's busy record; plugins → the mod; the auto
permission mode), the api lane's --mcp-config (an SDK session has no claude.ai connector), and Claude Code's own system
prompt. It registers in ~/.claude/sessions as every pane's claude does and takes the inbox socket's lines (cues, stackshot,
SendMessage) as turns by itself; every message of every turn — ours or inbound — is printed here.

THE SCREEN. Output scrolls above; the bottom three lines are a ❯ box the pane's readers know: a rule of ─, "❯ <what is typed>",
a rule (sala-web's input_box wants exactly that; sala's pane_draft reads the ❯ line; a dim hint on an empty line is a
placeholder to both). Keys arrive raw: printable text, Enter sends (the whole buffer, newlines of a bracketed paste kept),
Backspace, Ctrl-U clears (what sala's tui_send types over its own leftovers), Ctrl-C interrupts a running turn, Ctrl-L
redraws, Ctrl-D on an empty line leaves. Slash commands go to the CLI as text (skills, /compact), except the pane's own:
/exit and /quit leave; /remote-control, /rc, /feedback and /rename are answered with a line (no Remote Control, no
feedback panel, no rename here). Nothing printed here matches a terminal prompt sala waits out (pane_prompt).

EXIT: 0 — left on /exit, or the CLI ended on its own with 0 (the mod's exit, a SIGTERM); 1 — the CLI died or the SDK failed;
2 — usage; 3 — THE CREDIT REFUSED A TURN (an assistant message with error billing_error, or "credit balance" in an error
result or in the CLI's stderr): the driver first writes the shared credit record (lib/api_credit.py: ${XDG_STATE_HOME:-~/.local/state}/
api-credit/state.json, so the briefings and every other job see the refusal too), then the wrapper puts the pane back on subscription-1.
A turn that ends without an error removes the record (the key worked). The screen is cleared on the way out, as the
CLI clears its own, so the shell's prompt comes up on a clean pane.
"""
import argparse
import asyncio
import codecs
import os
import re
import shutil
import signal
import sys
import termios
import tty
import unicodedata
import uuid as uuidlib

# the shared credit record: loaded by path, because this runs under `python -I` (no sibling directory on sys.path)
import importlib.util
_spec = importlib.util.spec_from_file_location("api_credit", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib", "api_credit.py"))
api_credit = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(api_credit)

EXIT_OK, EXIT_FAIL, EXIT_USAGE, EXIT_CREDIT = 0, 1, 2, 3
CREDIT_RE = re.compile(r"credit balance", re.I)
DIM, UNDIM = "\x1b[2m", "\x1b[22m"
HINT = "a message for this session · /exit leaves"
PANE_ONLY = {"/remote-control": "no Remote Control on the sdk lane (no claude.ai login behind the key)",
             "/rc": "no Remote Control on the sdk lane (no claude.ai login behind the key)",
             "/feedback": "no feedback panel in this pane",
             "/rename": "no rename in this pane; the tmux session keeps its name (sala rename)"}


def read1(path):
    with open(path, encoding="utf-8") as f:
        return f.read().strip()


def cwidth(c):
    return 0 if unicodedata.combining(c) else (2 if unicodedata.east_asian_width(c) in "WF" else 1)


def swidth(s):
    return sum(cwidth(c) for c in s)


def tail_fit(s, n):
    """The longest tail of s that is at most n columns wide."""
    out, w = [], 0
    for c in reversed(s):
        cw = cwidth(c)
        if w + cw > n:
            break
        out.append(c)
        w += cw
    return "".join(reversed(out))


def one_line(s, n=120):
    s = " ".join(str(s).split())
    return s if len(s) <= n else s[: n - 1] + "…"


class Screen:
    """Output above, the ❯ box at the bottom (a tty); plain lines without a box otherwise."""

    def __init__(self, out):
        self.out = out
        self.tty = out.isatty()
        self.buf = ""
        self.box = False

    def _w(self, s):
        self.out.write(s)
        self.out.flush()

    def width(self):
        return shutil.get_terminal_size((80, 24)).columns

    def erase_box(self):
        if self.box:
            self._w("\r\x1b[1A\x1b[J")   # the cursor sits on the ❯ line: up to the rule, erase to the end of the screen
            self.box = False

    def draw_box(self):
        if not self.tty:
            return
        w = max(self.width(), 20)
        rule = "─" * (w - 1)
        shown = tail_fit(self.buf.replace("\n", "⏎"), w - 3)
        hint = DIM + HINT + UNDIM if not self.buf and w - 3 > len(HINT) else ""
        self._w(f"{rule}\r\n❯ {shown}{hint}\r\n{rule}\x1b[1A\r\x1b[{2 + swidth(shown)}C")
        self.box = True

    def say(self, text):
        self.erase_box()
        for line in str(text).split("\n"):
            self._w(line + "\r\n" if self.tty else line + "\n")
        self.draw_box()

    def redraw(self):
        self.erase_box()
        self.draw_box()

    def clear(self):
        self.erase_box()
        if self.tty:
            self._w("\x1b[2J\x1b[H")


class Driver:
    def __init__(self, a):
        self.a = a
        self.screen = Screen(sys.stdout)
        self.client = None
        self.busy = False
        self.exiting = False
        self.rc = None            # set once: the exit code the main loop leaves with
        self.done = asyncio.Event()
        self.dec = codecs.getincrementaldecoder("utf-8")(errors="replace")
        self.pending = ""         # key bytes decoded but not yet consumed (a split escape sequence or paste)
        self.in_paste = False
        self.paste = ""
        self.stderr_credit = False

    def credit_refused(self, why, text=""):
        """Write the shared credit record (what refused, as far as it can be said), then leave with EXIT_CREDIT."""
        try:
            api_credit.record_refusal("sdk-pane " + (self.a.session or self.a.name or self.a.resume or "new"), text or why)
        except OSError:
            pass   # the record is a courtesy to the other jobs; the pane's own fallback does not wait on it
        self.finish(EXIT_CREDIT, why)

    # ── leaving ──────────────────────────────────────────────────────────────
    def finish(self, rc, why=None):
        if self.rc is None:
            self.rc = rc
            self.done.set()   # first: the leave never waits on the screen (a pty gone with its tmux server raises EIO on every write)
            if why:
                try:
                    self.screen.say(why)
                except OSError:
                    pass

    # ── the SDK's messages ───────────────────────────────────────────────────
    def on_stderr(self, line):
        if CREDIT_RE.search(line):
            self.stderr_credit = True
        self.screen.say(DIM + "claude: " + line.rstrip() + UNDIM)

    async def can_use_tool(self, name, inp, ctx):
        from claude_agent_sdk import PermissionResultDeny
        self.screen.say(f"[sala-sdk] permission asked for {name} — denied: nobody can answer a prompt in this pane (the permission rules decide the rest)")
        return PermissionResultDeny(message="No one can answer a permission prompt in this pane (sala's sdk lane), so this call is denied. Use what the permission rules already allow, or leave the step for a session with a prompt.")

    def show(self, m):
        from claude_agent_sdk import (AssistantMessage, ResultMessage, SystemMessage, TextBlock, ToolResultBlock,
                                      ToolUseBlock, UserMessage)
        s = self.screen
        if isinstance(m, SystemMessage):
            if m.subtype == "init":
                d = m.data or {}
                mcp = [x for x in (d.get("mcp_servers") or []) if isinstance(x, dict)]
                up = [x.get("name") for x in mcp if x.get("status") == "connected"]
                down = len(mcp) - len(up)   # the user settings' plugins bring MCP servers with no auth here: counted, not listed
                mcps = (", ".join(up) if up else "none connected") + (f" ({down} not connected)" if down else "")
                s.say(f"connected: Claude Code {d.get('claude_code_version', '?')} under the Agent SDK · model {d.get('model', '?')} · "
                      f"{len(d.get('tools') or [])} tools · MCP: {mcps} · session {d.get('session_id', '?')}")
            elif m.subtype not in ("hook_started", "hook_response", "hook_progress"):
                s.say(DIM + f"[{m.subtype}]" + UNDIM)
            return
        if isinstance(m, AssistantMessage):
            pre = "  ↳ " if m.parent_tool_use_id else ""
            for b in m.content:
                if isinstance(b, TextBlock) and b.text.strip():
                    s.say("\n".join(pre + l for l in b.text.rstrip().split("\n")))
                elif isinstance(b, ToolUseBlock):
                    inp = b.input if isinstance(b.input, dict) else {}
                    what = next((inp[k] for k in ("description", "command", "file_path", "pattern", "query", "prompt", "url") if inp.get(k)), "")
                    s.say(DIM + f"{pre}⚙ {b.name}" + (f" — {one_line(what, 100)}" if what else "") + UNDIM)
            if m.error:
                text = " ".join(b.text for b in m.content if isinstance(b, TextBlock))
                s.say(f"⚠ the API refused the turn ({m.error}): {one_line(text, 300)}")
                if m.error == "billing_error" or CREDIT_RE.search(text):
                    self.credit_refused("sala-sdk: the API credit refused this turn — leaving so the pane comes back on the subscription-1 login", f"{m.error}: {text}")
            return
        if isinstance(m, UserMessage):
            o = m.origin   # an inbound turn (the inbox socket: a cue, stackshot, SendMessage): shown with where it came from
            kind = (o.get("kind") if isinstance(o, dict) else getattr(o, "kind", None)) or (str(o) if o else "")
            if isinstance(m.content, str):
                if o:
                    s.say(f"→ ({kind}) {one_line(m.content, 300)}")
            else:
                for b in m.content:
                    if isinstance(b, ToolResultBlock):
                        c = b.content if isinstance(b.content, str) else " ".join(x.get("text", "") for x in (b.content or []) if isinstance(x, dict))
                        s.say(DIM + ("  ✗ " if b.is_error else "  ↳ ") + one_line(c, 100) + UNDIM)
                    elif isinstance(b, TextBlock) and o:
                        s.say(f"→ ({kind}) {one_line(b.text, 300)}")
            return
        if isinstance(m, ResultMessage):
            self.busy = False
            cost = f" · ${m.total_cost_usd:.4f}" if m.total_cost_usd else ""
            s.say(DIM + f"— {m.duration_ms / 1000:.0f}s{cost}" + UNDIM)
            if m.is_error:
                s.say(f"⚠ {one_line(m.result or m.subtype, 300)}")
                if CREDIT_RE.search(m.result or "") or self.stderr_credit:
                    self.credit_refused("sala-sdk: the API credit refused this turn — leaving so the pane comes back on the subscription-1 login", m.result or "credit balance (the CLI's stderr)")
            else:
                api_credit.record_success()   # a turn the key paid for: the credit is there
            return

    async def receive(self):
        from claude_agent_sdk import ProcessError
        try:
            async for m in self.client.receive_messages():
                self.show(m)
                if self.rc is not None:
                    return
            if not self.exiting:
                self.finish(EXIT_OK, "sala-sdk: the CLI ended on its own — leaving")
        except ProcessError as e:
            text = f"{e} {e.stderr or ''}"
            if CREDIT_RE.search(text) or self.stderr_credit:
                self.credit_refused("sala-sdk: the API credit refused this session — leaving so the pane comes back on the subscription-1 login", text)
            elif e.exit_code == 0 or self.exiting:
                self.finish(EXIT_OK, "sala-sdk: the CLI ended — leaving")
            else:
                self.finish(EXIT_FAIL, f"sala-sdk: the CLI died (exit {e.exit_code}): {one_line(e.stderr or str(e), 400)}")
        except asyncio.CancelledError:
            raise
        except Exception as e:   # the SDK's own failures (a JSON line it could not read, the connection gone)
            if not self.exiting:
                self.finish(EXIT_FAIL, f"sala-sdk: the SDK stopped: {type(e).__name__}: {one_line(e, 400)}")
            else:
                self.finish(EXIT_OK)

    # ── keys ─────────────────────────────────────────────────────────────────
    def on_keys(self, fd, loop):
        try:
            data = os.read(fd, 65536)
        except OSError:
            data = b""
        if not data:
            loop.remove_reader(fd)
            if not self.a.tty:
                self.leave()
            return
        self.pending += self.dec.decode(data)
        self.consume()

    def consume(self):
        s = self.pending
        i, n = 0, len(s)
        while i < n:
            if self.in_paste:
                j = s.find("\x1b[201~", i)
                if j < 0:
                    self.paste += s[i:]
                    i = n
                    break
                self.paste += s[i:j]
                self.in_paste = False
                self.screen.buf += self.paste.replace("\r\n", "\n").replace("\r", "\n")
                self.paste = ""
                i = j + 6
                continue
            c = s[i]
            if c == "\x1b":
                if s.startswith("\x1b[200~", i):
                    self.in_paste = True
                    i += 6
                    continue
                if i + 1 >= n:
                    break   # a split sequence: wait for the rest
                if s[i + 1] == "[":
                    j = i + 2
                    while j < n and not ("\x40" <= s[j] <= "\x7e"):
                        j += 1
                    if j >= n:
                        break
                    i = j + 1
                    continue   # a CSI sequence (arrows, home, end): not taken
                if s[i + 1] == "O":
                    if i + 2 >= n:
                        break
                    i += 3
                    continue
                i += 1   # a lone Escape
                continue
            i += 1
            if c in "\r\n":
                self.submit()
            elif c in "\x7f\x08":
                self.screen.buf = self.screen.buf[:-1]
            elif c == "\x15":
                self.screen.buf = ""
            elif c == "\x03":
                if self.busy and self.client:
                    self.screen.say(DIM + "^C — interrupting the turn" + UNDIM)
                    asyncio.ensure_future(self.interrupt())
                else:
                    self.screen.buf = ""
            elif c == "\x04":
                if not self.screen.buf:
                    self.leave()
            elif c == "\x0c":
                pass
            elif c < " ":
                continue
            else:
                self.screen.buf += c
        self.pending = s[i:]
        self.screen.redraw()

    async def interrupt(self):
        try:
            await self.client.interrupt()
        except Exception as e:
            self.screen.say(DIM + f"interrupt failed: {one_line(e, 200)}" + UNDIM)

    def submit(self):
        text = self.screen.buf.strip()
        self.screen.buf = ""
        self.screen.redraw()
        if not text:
            return
        first = text.split(None, 1)[0].lower()
        if first in ("/exit", "/quit"):
            self.leave()
            return
        if first in PANE_ONLY:
            self.screen.say(f"[sala-sdk] {first}: {PANE_ONLY[first]}")
            return
        self.busy = True
        asyncio.ensure_future(self.send(text))

    async def send(self, text):
        try:
            await self.client.query(text)
        except Exception as e:
            self.busy = False
            self.screen.say(f"⚠ not sent: {one_line(e, 300)}")

    def leave(self):
        if not self.exiting:
            self.exiting = True
            self.finish(EXIT_OK, "sala-sdk: leaving — the conversation stays, sala resumes it")

    # ── the run ──────────────────────────────────────────────────────────────
    async def run(self):
        from claude_agent_sdk import ClaudeAgentOptions, ClaudeSDKClient
        a = self.a
        env = {"ANTHROPIC_API_KEY": read1(a.key_file)}
        if a.workspace_file:
            env["ANTHROPIC_CUSTOM_HEADERS"] = "anthropic-workspace-id: " + read1(a.workspace_file)
        extra = {}
        if a.name:
            extra["name"] = a.name
        kw = dict(system_prompt={"type": "preset", "preset": "claude_code"}, setting_sources=a.setting_sources.split(","),
                  env=env, extra_args=extra, stderr=self.on_stderr, can_use_tool=self.can_use_tool, max_buffer_size=16 * 1024 * 1024,
                  cwd=os.getcwd())
        if a.model:
            kw["model"] = a.model
        if a.effort:
            kw["effort"] = a.effort
        if a.mcp_config:
            kw["mcp_servers"] = a.mcp_config
        if a.cli:
            kw["cli_path"] = a.cli
        if a.resume:
            kw["resume"] = a.resume
        else:
            kw["session_id"] = a.new
        self.client = ClaudeSDKClient(ClaudeAgentOptions(**kw))
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGTERM, signal.SIGHUP):
            loop.add_signal_handler(sig, self.leave)
        if a.tty:
            loop.add_signal_handler(signal.SIGWINCH, self.screen.redraw)
        self.screen.say(f"sala-sdk: starting Claude Code under the Agent SDK on {'conversation ' + a.resume if a.resume else 'a new conversation ' + a.new}"
                        + (f" for {a.session}" if a.session else "") + (f" · model {a.model}" if a.model else "") + (f" · effort {a.effort}" if a.effort else ""))
        try:
            await self.client.connect()
        except Exception as e:
            text = f"{e} {getattr(e, 'stderr', '') or ''}"
            if CREDIT_RE.search(text):
                self.credit_refused(f"sala-sdk: could not start the CLI under the SDK: {one_line(e, 500)}", text)
            else:
                self.finish(EXIT_FAIL, f"sala-sdk: could not start the CLI under the SDK: {one_line(e, 500)}")
            return
        loop.add_reader(sys.stdin.fileno(), self.on_keys, sys.stdin.fileno(), loop)
        recv = asyncio.ensure_future(self.receive())
        await self.done.wait()
        loop.remove_reader(sys.stdin.fileno())
        try:
            await asyncio.wait_for(self.client.disconnect(), 15)
        except Exception:
            self.kill_cli()
        recv.cancel()
        try:
            await recv
        except (asyncio.CancelledError, Exception):
            pass

    def kill_cli(self):
        """The disconnect did not end the CLI in time: no claude on this conversation may outlive the pane program
        (a live one blocks every resume as "already live")."""
        try:
            p = self.client._transport._process   # the SDK keeps no public handle on the process
            p.kill()
        except Exception:
            pass


def main():
    p = argparse.ArgumentParser(description="the screen of an sdk-lane pane (lib/sdk-pane.sh runs it)", add_help=True)
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--resume", metavar="UUID", help="the conversation to resume")
    g.add_argument("--new", metavar="UUID", nargs="?", const="", help="a new conversation (a fresh id, or the one given)")
    p.add_argument("--name", help="the session's name for the CLI (--name)")
    p.add_argument("--session", help="the tmux session, for the screen's lines")
    p.add_argument("--model")
    p.add_argument("--effort")
    p.add_argument("--key-file", required=True)
    p.add_argument("--workspace-file")
    p.add_argument("--mcp-config", help="the --mcp-config file (the api lane's); nothing = no MCP server")
    p.add_argument("--cli", help="the claude launcher the SDK spawns (sala's own); nothing = the SDK's bundled CLI")
    p.add_argument("--setting-sources", default="user,project,local")
    a = p.parse_args()
    for f in (a.key_file, a.workspace_file, a.mcp_config):
        if f and not os.path.isfile(f):
            print(f"sala-sdk: no such file: {f}", file=sys.stderr)
            return EXIT_USAGE
    if a.resume is None:
        a.new = a.new or str(uuidlib.uuid4())
        if not a.name and a.session:
            a.name = a.session
    elif a.session and not a.name:
        a.name = a.session   # the row's name is the tmux session's, as /rename left it
    for u in (a.resume, a.new):
        if u:
            try:
                uuidlib.UUID(u)
            except ValueError:
                print(f"sala-sdk: not a conversation id: {u}", file=sys.stderr)
                return EXIT_USAGE
    a.tty = sys.stdin.isatty() and sys.stdout.isatty()
    old = None
    if a.tty:
        fd = sys.stdin.fileno()
        old = termios.tcgetattr(fd)
        tty.setraw(fd)
        sys.stdout.write("\x1b[?2004h")   # bracketed paste: sala-web's paste-buffer -p and a human's paste arrive whole
        sys.stdout.flush()
    d = Driver(a)
    try:
        asyncio.run(d.run())
    finally:
        if a.tty:
            try:
                if d.rc == EXIT_OK:
                    d.screen.clear()   # a clean leave clears the screen, as the CLI does; a failure leaves its lines for the reader
                else:
                    d.screen.erase_box()
                sys.stdout.write("\x1b[?2004l")
                sys.stdout.flush()
                termios.tcsetattr(fd, termios.TCSADRAIN, old)
            except OSError:
                pass   # the pty is gone (its tmux server died): nothing to restore, the exit code is still the driver's
    return d.rc if d.rc is not None else EXIT_FAIL


if __name__ == "__main__":
    sys.exit(main())
