"""The New session form's server side: the project list, the suggested
name, the spawn itself through sala's operation queue, and the operation's state while the page waits for the session.

The form is the one way sala's web UI makes a session, and it makes none itself: a submit is `sala op spawn NAME
--project <key> --role front|back [--mandate FILE] [--lane L] [--model M] [--effort E] --from sala-web --words "…"`,
run as an argv list (never a shell; nothing typed by a user reaches a command line except the name, the key, the lane,
the model and the effort, each checked here against the same shapes lib/op.sh and lib/spawn.sh check), and the queue
(lib/op.sh) plans it, refuses it or queues it. Its words are the owner's own action behind Cloudflare Access: "<name>, via
the sala web form: new <role> <name> in <project>, <HH:MM Www Mon Dth ZONE>, the zone being SALA_TZ (local time when unset)".

A SIDE CONVERSATION (lib/spawn.sh A SIDE SESSION; docs/side-sessions.md) goes through the same form and the same
queue: `side: true` with either `fork_of` (a running agent's name: the new session continues its conversation) or `project`
+ `item` (a fresh session about that board item, `agents` the item's involved agents, comma-joined), no role, and a blank
name meaning "suggest one" (`sala spawn --suggest-name --side …`, filled in by the app). The argv is `sala op spawn NAME
--side [--fork-of AGENT | --project K --item ID] [--agents A,B] [--mandate FILE] …`. The item id is any form stackshot shows
(board#N, board-tmp-box#N, sN).

The mandate's transport (lib/op.sh, THE MANDATE'S TRANSPORT): the text is written to state_dir/mandates/<random>-<name>.md
(0600) and that path goes on the command line as `--mandate FILE`, so a multi-line Korean mandate with quotes and a
leading dash arrives as bytes in a file, never as an argument; the queue passes a readable file as it is and the session
reads it at its first prompt, after the operation has ended, so the file stays (pruned with the uploads after 30 days). A
spawn the queue refuses leaves no file.

What the queue answers (its exit code, lib/op.sh and lib/spawn.sh): 0 queued, `queued op <id>: …` on stdout; 3 the name
is not on the project's agents map, the refusal on stderr and stackshot's register command on stdout from the `REGISTER:
<key>` line to the end (the page's keeper was asked once by a stackshot message, said on stderr); 4 no such page,
`NO-PAGE: <key>`; 1 or 2 refused (a name already live, a shape, a lane that cannot launch), the reason on stderr and in
the plan's lines marked ✗. The page shows each as it is (text, never markup).

The project list is read from the pages themselves, the files stackshot's pages.py checks a key against (`resolve
<key>` is `os.path.exists(<brain>/<key>.md)`): every `<dir>/**/*.md` under stackshot's pages checkout for its page dirs,
a README and a redirect or archive stub left out, the key and the frontmatter's title only; read-only, cached 30 s. The
operation's state is read from the queue's marker, $SALA_STATE_DIR/ops/<id>.op (then ops/done/), key=value lines.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import os
import re
import secrets
import shutil
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from . import lanestate as LS
from . import tz
from .config import owner_name

NAME_MAX = 48                       # sala's SALA_AGENT_NAME_MAX: tmux's session name, the /rename typed, the sidebar's rows
NAME_RE = re.compile(r"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$")   # agent_name_ok: lowercase, digits, dashes, no dash at either end
SEGMENT_RE = NAME_RE                                         # page_key_ok: each segment of <dir>/<slug>[/<sub>…] the same
ROLES = ("front", "back")
EFFORTS = ("low", "medium", "high", "xhigh", "max")          # lib/spawn.sh's list
ITEM_RE = re.compile(r"^(?:board#\d+|board-tmp-[a-z0-9]+(?:-[a-z0-9]+)*#\d+|[a-z]\d+)$")   # lib/common.sh item_id_ok
AGENTS_RE = re.compile(r"^[a-z0-9-]+(?:,[a-z0-9-]+)*$")                                      # spawn --agents
MODEL_RE = re.compile(r"^[A-Za-z0-9._-]+$")                  # spawn's --model check: typed unquoted into the pane's shell
MODELS = ("opus", "sonnet", "haiku", "fable")                # the family aliases the form offers (the CLI resolves each to the family's latest)
SHOWN_MODEL_RE = re.compile(r"^[A-Za-z0-9._\[\]-]{1,64}$")   # a model as settings.json writes it ("opus", "claude-opus-5", "opus[1m]"): shown, never run
MANDATE_MAX = 20 * 1024                                      # bytes of UTF-8
BODY_MAX = 64 * 1024                                         # the whole JSON body
OP_ID_RE = re.compile(r"^\d{1,12}-\d{1,9}$")                 # <epoch>-<pid>
FROM = "sala-web"                                            # the queue's --from: who heard the owner
QUEUE_TIMEOUT = 90.0        # the plan runs spawn --dry-run: two pages.py calls (15 s each at most) and the tmux checks
SUGGEST_TIMEOUT = 20.0
LANE_DEFAULT_TIMEOUT = 4.0   # `sala lane --json` for the form's "use default (<lane>)": past this the label says "use default" alone
PAGES_TTL = 30.0
MANDATE_RE = re.compile(r"^[0-9a-f]{16}-[a-z0-9-]{1,48}\.md$")


def page_key_ok(key: str, dirs: list[str]) -> bool:
    """lib/common.sh page_key_ok: `<dir>/<slug>[/<sub>…]`, the dir one of `dirs`, every segment lowercase letters, digits
    and dashes with no dash at either end."""
    if not isinstance(key, str) or "/" not in key:
        return False
    head, rest = key.split("/", 1)
    if head not in dirs or not rest:
        return False
    return all(SEGMENT_RE.match(seg) for seg in rest.split("/"))


def prefix_ok(prefix: str) -> bool:
    """`spawn --suggest-name --prefix`: an agent-name prefix, with room left for `-<word>` (lib/spawn.sh checks the same)."""
    return isinstance(prefix, str) and 0 < len(prefix) <= NAME_MAX - 3 and bool(NAME_RE.match(prefix))


def name_ok(name: str) -> bool:
    return isinstance(name, str) and 0 < len(name) <= NAME_MAX and bool(NAME_RE.match(name))


def store_id(shown: str) -> str:
    """An item id as stackshot shows it -> the id of its store, which the client API's item-facts takes (pages.py item_key):
    board#N -> gN, a temporary board-tmp-box#N -> lN, an older sN -> sN; "" when it is none of them."""
    if not isinstance(shown, str) or not ITEM_RE.match(shown):
        return ""
    if shown.startswith("board-tmp-"):
        return "l" + shown.rsplit("#", 1)[1]
    if shown.startswith("board#"):
        return "g" + shown[len("board#"):]
    return shown


def zone_stamp(now: datetime | None = None) -> str:
    """`14:05 Thu Oct 15th UTC`: the time and date in the SALA_TZ zone (local when unset) with the zone's own label, the form
    sala's local_human writes (lib/common.sh)."""
    t = tz.convert(now) if now is not None else tz.now()
    d = t.day
    suf = "th" if 11 <= d % 100 <= 13 else {1: "st", 2: "nd", 3: "rd"}.get(d % 10, "th")
    return t.strftime("%H:%M %a %b ") + f"{d}{suf} {t.tzname()}"


def words_for(role: str, name: str, project: str, now: datetime | None = None) -> str:
    """The queue's `--words`: the owner's own action, said as the form heard it."""
    return f"{owner_name()}, via the sala web form: new {role} {name} in {project}, {zone_stamp(now)}"


def side_words_for(r: "SpawnRequest", now: datetime | None = None) -> str:
    """The same for a side conversation: what it is about, or whose conversation it forks."""
    what = f"a fork of {r.fork_of}" + (f", about {r.item}" if r.item else "") if r.fork_of else f"about {r.item} in {r.project}"
    return f"{owner_name()}, via the sala web form: new side conversation {r.name} ({what}), {zone_stamp(now)}"


# ── what a session follows when the form leaves lane, model or effort empty ─────────────────────────────────
def claude_defaults(claude_dir: Path) -> dict[str, str]:
    """{"model", "effort"}: what a spawn with no --model and no --effort follows, read from the settings file the CLI reads
    (claude_dir/settings.json, ~/.claude): the top-level `model`, and its effort, which is `modelSettings.<model id>.effortLevel`
    of the model's family (the key naming the family, the last one when several do), else the top-level `effortLevel`. A value
    it cannot read is "": the form then says "use default" alone and never guesses. Read-only; the text is shown on the
    page, never run, so a stray character is simply dropped by the shape check. It is the settings file of THIS user's ~/.claude:
    a lane that runs with its own CLAUDE_CONFIG_DIR (the subscription-2 lane's login directory) may follow another settings file, so the shown model and effort are what the default lane follows, not a promise for every lane."""
    try:
        doc = json.loads((claude_dir / "settings.json").read_text(encoding="utf-8", errors="replace"))
    except (OSError, ValueError):
        return {"model": "", "effort": ""}
    if not isinstance(doc, dict):
        return {"model": "", "effort": ""}
    model = doc.get("model") if isinstance(doc.get("model"), str) and SHOWN_MODEL_RE.match(doc.get("model") or "") else ""
    effort = ""
    ms = doc.get("modelSettings") if isinstance(doc.get("modelSettings"), dict) else {}
    family = next((f for f in MODELS if f in model.lower()), "")
    keys = sorted(k for k, v in ms.items() if isinstance(k, str) and isinstance(v, dict) and (k == model or (family and family in k.lower())))
    for k in reversed(keys):
        v = ms[k].get("effortLevel")
        if isinstance(v, str) and v in EFFORTS:
            effort = v
            break
    if not effort and isinstance(doc.get("effortLevel"), str) and doc["effortLevel"] in EFFORTS:
        effort = doc["effortLevel"]
    return {"model": model, "effort": effort}


# ── the project list ─────────────────────────────────────────────────────────
def _frontmatter(path: Path) -> dict[str, str]:
    """`title` and `type` from a page's frontmatter (the first `---` block), plain scalars only; {} without one."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            head = f.read(8192)
    except OSError:
        return {}
    if not head.startswith("---"):
        return {}
    out: dict[str, str] = {}
    for line in head.splitlines()[1:]:
        if line.strip() == "---":
            break
        m = re.match(r"^(title|type):\s*(.*?)\s*$", line)
        if m:
            v = m.group(2)
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                v = v[1:-1]
            out[m.group(1)] = v
    return out


def _scan(brain: Path, dirs: list[str]) -> list[tuple[str, dict[str, str]]]:
    """[(key, frontmatter)] for every page under brain/<dir>/**/*.md that page_key_ok accepts, a README left out, sorted by key."""
    out: list[tuple[str, dict[str, str]]] = []
    for d in dirs:
        root = brain / d
        if not root.is_dir():
            continue
        for f in sorted(root.rglob("*.md")):
            if f.name == "README.md" or not f.is_file():
                continue
            key = f.relative_to(brain).with_suffix("").as_posix()
            if page_key_ok(key, dirs):
                out.append((key, _frontmatter(f)))
    return sorted(out, key=lambda kv: kv[0])


def _pages_of(scanned: list[tuple[str, dict[str, str]]]) -> list[dict]:
    """[{key, title}]: a redirect or archive stub (pages.py read_pages leaves them out too) is not a page a session can belong to."""
    return [{"key": k, "title": fm.get("title", "")} for k, fm in scanned if fm.get("type", "").strip().lower() not in ("redirect", "archive")]


def _types_of(scanned: list[tuple[str, dict[str, str]]]) -> dict[str, str]:
    """{key: the page's frontmatter `type`, lowercased} for every scanned page ("" where it names none)."""
    return {k: fm.get("type", "").strip().lower() for k, fm in scanned}


def list_pages(brain: Path, dirs: list[str]) -> list[dict]:
    """[{key, title}] for every page under brain/<dir>/**/*.md, sorted by key: a README and a redirect or archive stub
    (pages.py read_pages leaves them out too) are not pages a session can belong to."""
    return _pages_of(_scan(brain, dirs))


def page_types(brain: Path, dirs: list[str]) -> dict[str, str]:
    """{key: `type`} of every page under brain/<dir>/**/*.md (a README left out): the one field that says which pages are
    projects (`type: project`)."""
    return _types_of(_scan(brain, dirs))


class PagesCache:
    """The project list, read from the pages at most every PAGES_TTL seconds; a missing pages checkout is an empty list
    with its reason. The same read keeps each page's `type` (`types()`), which says which pages are registered projects."""

    def __init__(self, brain: Path | None, dirs: list[str]):
        self.brain = brain
        self.dirs = dirs
        self._pages: list[dict] = []
        self._types: dict[str, str] | None = None
        self._at: float | None = None   # None: not read yet. Never 0.0: the monotonic clock counts from the machine's boot, so within PAGES_TTL of it 0.0 looks "just read"
        self._lock = asyncio.Lock()
        self.error: str | None = None

    async def _refresh(self) -> None:
        if self._at is not None and time.monotonic() - self._at < PAGES_TTL:
            return
        self._at = time.monotonic()
        if self.brain is None or not self.brain.is_dir():
            self.error = (f"no pages checkout at {self.brain}" if self.brain is not None
                          else "no pages checkout: SALA_BRAIN_DIR is not set")
            self._pages, self._types = [], None
            return
        try:
            scanned = await asyncio.to_thread(_scan, self.brain, self.dirs)
            self._pages, self._types = _pages_of(scanned), _types_of(scanned)
            self.error = None
        except OSError as e:
            self.error = f"could not read the pages: {e.strerror or e}"

    async def get(self) -> list[dict]:
        async with self._lock:
            await self._refresh()
            return self._pages

    async def types(self) -> dict[str, str] | None:
        """{page key: type}, or None when there is no pages checkout to read (the caller then has nothing to filter on)."""
        async with self._lock:
            await self._refresh()
            return self._types


# ── the request's shape ──────────────────────────────────────────────────────
@dataclass
class SpawnRequest:
    project: str
    role: str
    name: str
    mandate: str = ""
    lane: str = ""
    model: str = ""
    effort: str = ""
    side: bool = False       # a side conversation: no role; fork_of XOR project + item
    item: str = ""
    fork_of: str = ""
    agents: str = ""


def validate(body: object, dirs: list[str], lanes: list[str]) -> SpawnRequest | tuple[int, str]:
    """The form's fields, checked against the shapes the backend checks (lib/op.sh op_shape spawn, lib/spawn.sh), or
    (status, message). Nothing else in the body is accepted."""
    if not isinstance(body, dict):
        return 400, "the body must be a JSON object"
    unknown = sorted(set(body) - {"project", "role", "name", "mandate", "lane", "model", "effort", "side", "item", "fork_of", "agents"})
    if unknown:
        return 400, f"unknown fields: {', '.join(unknown)}"
    keys = ("project", "role", "name", "mandate", "lane", "model", "effort", "item", "fork_of", "agents")
    s = {k: body.get(k) for k in keys}
    for k, v in s.items():
        if v is not None and not isinstance(v, str):
            return 400, f"{k} must be a string"
    if body.get("side") not in (None, True, False):
        return 400, "side must be true or false"
    project, role, name = (s["project"] or "").strip(), (s["role"] or "").strip(), (s["name"] or "").strip()
    item, fork_of, agents = (s["item"] or "").strip(), (s["fork_of"] or "").strip(), (s["agents"] or "").strip()
    if body.get("side") is True:
        return _validate_side(s, project, name, item, fork_of, agents, dirs, lanes)
    if item or fork_of or agents:
        return 400, "item, fork_of and agents go with side"
    if not page_key_ok(project, dirs):
        return 400, f"project must be a page key: <dir>/<slug> with the dir one of {', '.join(dirs)}, lowercase letters, digits and dashes"
    if role not in ROLES:
        return 400, "role must be front or back"
    if not name_ok(name):
        return 400, f"name must be lowercase letters, digits and dashes, no dash at either end, at most {NAME_MAX} characters"
    mandate = (s["mandate"] or "").replace("\r\n", "\n").replace("\r", "\n")
    if len(mandate.encode("utf-8")) > MANDATE_MAX:
        return 413, f"the mandate is over {MANDATE_MAX // 1024} KB"
    if role == "back" and not mandate.strip():
        return 400, "a back agent needs a mandate: a background agent reads it at its first prompt, and nobody briefs it"
    lane, model, effort = (s["lane"] or "").strip(), (s["model"] or "").strip(), (s["effort"] or "").strip()
    lane = LS.renamed(lane)   # a payload from a form loaded before a rename, or a client of the API, may still say the old word (lanestate.RENAMED); sala takes it too
    if lane and lane not in lanes:
        return 400, f"lane must be one of {', '.join(lanes)}"
    if model and not MODEL_RE.match(model):
        return 400, "model: letters, digits, dots, dashes and underscores only"
    if effort and effort not in EFFORTS:
        return 400, f"effort must be one of {', '.join(EFFORTS)}"
    return SpawnRequest(project, role, name, mandate if mandate.strip() else "", lane, model, effort)


def _validate_side(s: dict, project: str, name: str, item: str, fork_of: str, agents: str, dirs: list[str], lanes: list[str]) -> SpawnRequest | tuple[int, str]:
    """A side conversation's fields (the module docstring): the same shapes lib/op.sh checks at queue time."""
    if (s["role"] or "").strip():
        return 400, "a side conversation takes no role: it is on no page's agents map"
    if fork_of:
        if project or agents:
            return 400, "a fork takes no project and no agents: it continues one agent's conversation"
        if not name_ok(fork_of):
            return 400, "fork_of must be a running agent's session name"
    else:
        if not project:
            return 400, "a side conversation needs fork_of (an agent to fork) or a project and an item"
        if not item:
            return 400, "a side conversation about a project needs the item it is about"
    if project and not page_key_ok(project, dirs):
        return 400, f"project must be a page key: <dir>/<slug> with the dir one of {', '.join(dirs)}, lowercase letters, digits and dashes"
    if item and not ITEM_RE.match(item):
        return 400, "item must be a board item id as stackshot shows it (board#N, board-tmp-box#N, sN)"
    if agents and not AGENTS_RE.match(agents):
        return 400, "agents: agent names joined by commas (lowercase letters, digits, dashes)"
    if name and (not name_ok(name) or "-side-" not in name):
        return 400, f"name must be an agent name containing -side- (at most {NAME_MAX} characters), or blank for a suggested one"
    mandate = (s["mandate"] or "").replace("\r\n", "\n").replace("\r", "\n")
    if len(mandate.encode("utf-8")) > MANDATE_MAX:
        return 413, f"the mandate is over {MANDATE_MAX // 1024} KB"
    lane, model, effort = (s["lane"] or "").strip(), (s["model"] or "").strip(), (s["effort"] or "").strip()
    lane = LS.renamed(lane)   # a payload from a form loaded before a rename, or a client of the API, may still say the old word (lanestate.RENAMED); sala takes it too
    if lane and lane not in lanes:
        return 400, f"lane must be one of {', '.join(lanes)}"
    if model and not MODEL_RE.match(model):
        return 400, "model: letters, digits, dots, dashes and underscores only"
    if effort and effort not in EFFORTS:
        return 400, f"effort must be one of {', '.join(EFFORTS)}"
    return SpawnRequest(project, "", name, mandate if mandate.strip() else "", lane, model, effort, True, item, fork_of, agents)


# ── sala ─────────────────────────────────────────────────────────────────────
def resolve_cmd(cmd: list[str]) -> list[str]:
    """The sala command with its program found: on PATH, else sala's own install places (`~/.local/bin/sala`,
    `~/salamander/bin/salamander`), so a manual `uv run sala-web` without ~/.local/bin on PATH still finds it."""
    if not cmd:
        return cmd
    prog = cmd[0]
    if "/" in prog or shutil.which(prog):
        return cmd
    for p in (Path.home() / ".local" / "bin" / prog, Path.home() / "salamander" / "bin" / "salamander"):
        if p.is_file() and os.access(p, os.X_OK):
            return [str(p), *cmd[1:]]
    return cmd


async def run(cmd: list[str], timeout: float) -> tuple[int, str, str]:
    """argv, never a shell; (returncode, stdout, stderr), decoded with replacement. OSError and TimeoutError pass up."""
    proc = await asyncio.create_subprocess_exec(*cmd, stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.PIPE,
                                                stderr=asyncio.subprocess.PIPE)
    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except (asyncio.TimeoutError, TimeoutError):
        with contextlib.suppress(ProcessLookupError):
            proc.kill()
        await proc.wait()
        raise TimeoutError(f"{Path(cmd[0]).name} did not finish within {int(timeout)} s")
    return proc.returncode or 0, out.decode("utf-8", "replace"), err.decode("utf-8", "replace")


def argv_for(cmd: list[str], r: SpawnRequest, mandate_file: Path | None, words: str) -> list[str]:
    """`sala op spawn NAME --project K --role R [--mandate FILE] [--lane L] [--model M] [--effort E] --from sala-web
    --words "…"`: the folded options only when set (empty = the session follows the settings, as the form says)."""
    if r.side:
        argv = [*cmd, "op", "spawn", r.name, "--side"]
        argv += ["--fork-of", r.fork_of] if r.fork_of else ["--project", r.project]
        if r.item:
            argv += ["--item", r.item]
        if r.agents:
            argv += ["--agents", r.agents]
    else:
        argv = [*cmd, "op", "spawn", r.name, "--project", r.project, "--role", r.role]
    if mandate_file is not None:
        argv += ["--mandate", str(mandate_file)]
    if r.lane:
        argv += ["--lane", r.lane]
    if r.model:
        argv += ["--model", r.model]
    if r.effort:
        argv += ["--effort", r.effort]
    return argv + ["--from", FROM, "--words", words]


def write_mandate(mandates_dir: Path, name: str, text: str) -> Path:
    """The mandate as a file the session reads (0600, a random prefix, ending in a newline as a file does)."""
    mandates_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = mandates_dir / f"{secrets.token_hex(8)}-{name}.md"
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
        f.write(text if text.endswith("\n") else text + "\n")
    return path


def _block(stdout: str, marker: str) -> str:
    """The lines from the last `<marker>: ` line at column 0 to the end (lib/op.sh prints the block once more,
    unindented, after the refusal)."""
    lines = stdout.splitlines()
    starts = [i for i, l in enumerate(lines) if l.startswith(marker + ": ")]
    if not starts:
        return ""
    return "\n".join(lines[starts[-1]:]).rstrip("\n")


def _refusal(stdout: str, stderr: str, rc: int) -> str:
    """What to show for a refused spawn: the stderr lines and the plan's ✗ lines, in order, once each."""
    seen: list[str] = []
    for l in stderr.splitlines() + [l for l in stdout.splitlines() if "✗" in l]:
        t = l.strip()
        if t and t not in seen:
            seen.append(t)
    return "\n".join(seen)[:4000] or f"sala op spawn exited {rc}"


QUEUED_RE = re.compile(r"^queued op (\S+):", re.M)


def parse_result(rc: int, stdout: str, stderr: str, r: SpawnRequest) -> tuple[int, dict]:
    """(status, body) for the page from the queue's exit code and output (the module docstring)."""
    if rc == 0:
        m = QUEUED_RE.search(stdout)
        if not m:
            return 502, {"ok": False, "code": "error", "error": "sala exited 0 without a `queued op` line", "output": stdout[-4000:]}
        body = {"ok": True, "op": m.group(1), "name": r.name, "project": r.project, "role": r.role, "output": stdout.strip()[-4000:]}
        if r.side:
            body["side"] = True   # only a side conversation says so: the New session form's answer is unchanged
        return 202, body
    if rc == 3:
        keeper = next((l.strip() for l in stderr.splitlines() if "keeper was asked" in l), None)
        return 409, {"ok": False, "code": "not-listed", "page": r.project, "name": r.name, "role": r.role,
                     "block": _block(stdout, "REGISTER"), "keeper": keeper, "error": _refusal(stdout, stderr, rc)}
    if rc == 4:
        return 409, {"ok": False, "code": "no-page", "page": r.project, "error": _refusal(stdout, stderr, rc)}
    return 409, {"ok": False, "code": "refused", "error": _refusal(stdout, stderr, rc), "exit": rc}


# ── the operation's marker ───────────────────────────────────────────────────
def op_state(sala_state: Path, op_id: str) -> dict | None:
    """The queue's record of one operation (lib/op.sh THE MARKER): state, result and the stamps; None when there is none."""
    if not OP_ID_RE.match(op_id):
        return None
    for p in (sala_state / "ops" / f"{op_id}.op", sala_state / "ops" / "done" / f"{op_id}.op"):
        try:
            text = p.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        rec: dict = {"op": op_id, "state": "", "result": "", "args": []}
        for line in text.splitlines():
            k, _, v = line.partition("=")
            if k == "arg":
                rec["args"].append(v)
            elif k in ("state", "result", "verb", "from", "time", "started", "ended", "unit"):
                rec[k] = v
        return rec
    return None


def _op_key(op_id: str) -> tuple[int, int]:
    """(epoch, pid) of an operation id: the order the queue starts them in (lib/op.sh op_files: oldest first)."""
    epoch, _, pid = op_id.partition("-")
    return int(epoch), int(pid)


def queue_ahead(sala_state: Path, op_id: str) -> list[dict]:
    """What a queued operation waits behind, as the queue itself orders it (lib/op.sh op_tick_locked): the operation running
    now (one at a time; a `waiting` one has handed the queue on) and every queued one older than this. Each is {"op", "verb",
    "arg", "state"}, the running one first; arg is the first argument unless that is a flag. [] when nothing is ahead or the
    queue folder cannot be read."""
    if not OP_ID_RE.match(op_id):
        return []
    mine = _op_key(op_id)
    try:
        names = [p.stem for p in (sala_state / "ops").glob("*.op") if OP_ID_RE.match(p.stem) and p.stem != op_id]
    except OSError:
        return []
    ahead = []
    for name in sorted(names, key=_op_key):
        rec = op_state(sala_state, name)
        if rec is None or rec.get("state") not in ("queued", "running"):
            continue
        if rec["state"] == "queued" and _op_key(name) > mine:
            continue
        arg = next((a for a in rec["args"][:1] if not a.startswith("-")), "")
        ahead.append({"op": name, "verb": rec.get("verb") or "operation", "arg": arg, "state": rec["state"]})
    ahead.sort(key=lambda a: a["state"] != "running")   # stable: the running one first, the rest in queue order
    return ahead


def behind_line(ahead: list[dict]) -> str:
    """One short line for a person: what the operation waits behind, counted by verb ("Waiting behind 2 retires and 1
    rename (running now: retire demo-scratch4)."); a single one is named. "" when nothing is ahead."""
    if not ahead:
        return ""

    def named(a: dict) -> str:
        return f"{a['verb']} {a['arg']}".strip()
    if len(ahead) == 1:
        return f"Waiting behind {named(ahead[0])} ({ahead[0]['state']})."
    counts: dict[str, int] = {}
    for a in ahead:
        counts[a["verb"]] = counts.get(a["verb"], 0) + 1
    parts = [f"{n} {v}{'' if n == 1 else 's'}" for v, n in counts.items()]
    what = parts[0] if len(parts) == 1 else ", ".join(parts[:-1]) + " and " + parts[-1]
    running = next((a for a in ahead if a["state"] == "running"), None)
    return f"Waiting behind {what}" + (f" (running now: {named(running)})" if running else "") + "."


def op_status(sala_state: Path, op_id: str) -> dict | None:
    """op_state for the page: a queued operation also says what it waits behind (`behind`, `behind_line`)."""
    rec = op_state(sala_state, op_id)
    if rec is not None and rec.get("state") == "queued":
        ahead = queue_ahead(sala_state, op_id)
        rec["behind"], rec["behind_line"] = ahead, behind_line(ahead)
    return rec


def prune_mandates(mandates_dir: Path, max_age_days: int) -> None:
    cutoff = time.time() - max_age_days * 86400
    if mandates_dir.is_dir():
        for p in mandates_dir.iterdir():
            try:
                if MANDATE_RE.match(p.name) and p.stat().st_mtime < cutoff:
                    p.unlink()
            except OSError:
                pass
