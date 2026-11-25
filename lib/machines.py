#!/usr/bin/env python3
"""machines.py: the fleet's machines as plain data (`sala machines`, `sala host`, the web Machines tab; docs/subcommands.md).

The machines are spread over a few files the owner keeps by hand, in one data folder (the one that holds the fleet names file, SALA_FLEET_NAMES):

  fleet-names.tsv                        <os hostname> TAB <fleet name> TAB <board letter>; a comment line `# <letter> = <fleet name>, retired ...` reserves
                                         the letter of a machine that is gone
  claude/tailnet-route/candidates.conf   `host <hostname> <ipv4> <ipv6>` lines (the tailnet's hosts and their addresses)
  ssh/fleet.conf                         ssh `Host <alias>` blocks
  claude/host-move/machine-holds.toml    `[[hosts]]` records (role, host, name): which machine hosts sala (`sala-host`) and stackshot (`stackshot-host`)
  claude/machine-follow/machines.toml    `[machines.<hostname>]` tables (SALA_MACHINE_FOLLOW_MACHINES names it; it never moved)
  claude/host-move/machine_holds.py      the reader and writer of the host record (`host ROLE`, `set-host ROLE HOST`), run by `sala host`

`machine_list()` reads the first five, read-only, and returns one entry per machine, whichever of the files name it: a machine present in one file and
missing from another is listed with the missing parts empty, never an error; a file that is not there or cannot be read counts as empty. An entry:

  name       the fleet name (the file's second column), else the name the first file that lists the machine gives it
  hostname   the OS hostname: the names file's first column, else the candidates' (`hostname -s` there), else the holds' or the follow list's, else ""
  letter     the board letter, "" for a machine with none
  ssh        the ssh alias of its `Host` block, "" for none
  addresses  [ipv4, ipv6] from candidates.conf, [] for none
  roles      the host roles it holds, from `[[hosts]]`: "sala-host", "stackshot-host"
  retired    true where the names file says so (its comment line for the machine's letter)
  sources    the files it came from, in the order above: fleet-names.tsv, candidates.conf, fleet.conf, machine-holds.toml, machines.toml

A second, separate call adds readings to each entry (`read_with_readings`: what the heartbeat posts and `sala machines --json` prints; `machine_list()` itself runs no program, so the
web tab and `sala host` are untouched). Four keys, after the ones above, each optional for a reader (absent or null means unknown):

  online     true / false / null: the tailnet shows the machine connected at the reading (`tailscale status --json`, run on this box: no ssh, no network of its own); null = no reading
  last_seen  epoch seconds of the last moment the tailnet knew the machine online, or null (null while it is online, and when unknown)
  versions   {text: text}, at most 16 entries: what sala read on the machine itself, so only on the box making the reading ({"claude": ..., "sala": <short commit>}); {} = sala read nothing
  checked    epoch seconds the entry was read; an entry whose `checked` is older than the post that carries it is stale

The machines are in the names file's order (retired ones after the others), then those only the other files name, in the order the files are read. Names meet
without regard to case, and a hostname the names file lists (`HOST-OS10`) meets its fleet name. Standard library only; nothing is ever written here.
`python3 lib/machines.py list [--json]` and `host ...` are what the two CLI verbs run; the paths come from SALA_FLEET_NAMES and SALA_MACHINE_FOLLOW_MACHINES
in the environment (the shell side passes sala's settings), and MACHINE_HOLDS_TOML, MACHINE_HOLDS_CANDIDATES (else TNR_CONF) move the two files the holds script
itself lets the environment move, so the verbs and the script always read the same ones."""
from __future__ import annotations

import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
import tomllib
from datetime import datetime
from pathlib import Path

NAMES_FILE = "fleet-names.tsv"
CANDIDATES_FILE = "candidates.conf"
SSH_FILE = "fleet.conf"
HOLDS_FILE = "machine-holds.toml"
FOLLOW_FILE = "machines.toml"
SCRIPT_FILE = "machine_holds.py"
LAYOUT = {   # where each file is, relative to the data folder (the folder of the fleet names file)
    "candidates": "claude/tailnet-route/candidates.conf",
    "ssh": "ssh/fleet.conf",
    "holds": "claude/host-move/machine-holds.toml",
    "follow": "claude/machine-follow/machines.toml",
    "script": "claude/host-move/machine_holds.py",
}
ROLES = ("sala-host", "stackshot-host")
KEYS = ("name", "hostname", "letter", "ssh", "addresses", "roles", "retired", "sources")
READING_KEYS = ("online", "last_seen", "versions", "checked")   # what `read_with_readings` adds after KEYS on each entry, in this order
SCHEMA = 1
MAX_VERSIONS = 16               # a row's `versions` holds at most this many entries
TAILSCALE_TIMEOUT = 10          # seconds `tailscale status --json` may take
_RETIRED = re.compile(r"#\s*([A-Za-z0-9])\s*=\s*([A-Za-z0-9][A-Za-z0-9._-]*)\s*,\s*retired\b")


def _path(v) -> Path | None:
    return Path(str(v)).expanduser() if v else None


def paths(fleet_names=None, follow=None) -> dict[str, Path | None]:
    """Where each file is: the names file as given, the others beside it (LAYOUT), the follow list as given when it is (SALA_MACHINE_FOLLOW_MACHINES),
    and the two files the holds script lets the environment move as the script reads them. A key is None when nothing names a place for it."""
    names = _path(fleet_names)
    base = names.parent if names else None
    out: dict[str, Path | None] = {"fleet_names": names}
    for k, rel in LAYOUT.items():
        out[k] = base / rel if base else None
    if follow:
        out["follow"] = _path(follow)
    holds_env = os.environ.get("MACHINE_HOLDS_TOML")
    cand_env = os.environ.get("MACHINE_HOLDS_CANDIDATES") or os.environ.get("TNR_CONF")
    if holds_env:
        out["holds"] = _path(holds_env)
    if cand_env:
        out["candidates"] = _path(cand_env)
    return out


def _lines(p: Path | None) -> list[str] | None:
    """The lines of a text file; None when there is no path, no file or it cannot be read."""
    if p is None:
        return None
    try:
        return p.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError):
        return None


def _toml(p: Path | None) -> dict | None:
    if p is None:
        return None
    try:
        with open(p, "rb") as f:
            return tomllib.load(f)
    except (OSError, ValueError):
        return None


class _Book:
    """The machines found so far, met by lower-cased name; an alias (an OS hostname) leads to its fleet name's entry."""

    def __init__(self) -> None:
        self.by: dict[str, dict] = {}
        self.alias: dict[str, str] = {}
        self.missed: list[str] = []    # the files that were named and could not be

    def get(self, name: str, source: str, create: bool = True) -> dict | None:
        key = name.lower()
        key = self.alias.get(key, key)
        e = self.by.get(key)
        if e is None and create:
            e = self.by[key] = {"name": name, "hostname": "", "letter": "", "ssh": "", "addresses": [], "roles": [], "retired": False, "sources": []}
        if e is not None and source not in e["sources"]:
            e["sources"].append(source)
        return e


def machine_list(fleet_names=None, follow=None, *, candidates=None, ssh=None, holds=None) -> list[dict]:
    """Every machine the files name, as the entries described at the top of this file. `fleet_names` and `follow` are paths (or None); the other three
    default to the places beside the names file (paths()). Never raises for a missing or malformed file."""
    return read_list(fleet_names, follow, candidates=candidates, ssh=ssh, holds=holds)[0]


def read_list(fleet_names=None, follow=None, *, candidates=None, ssh=None, holds=None) -> tuple[list[dict], list[str]]:
    """`machine_list` and, with it, the files that were named and could not be read (the file names, as `sala machines` says them): what the heartbeat posts to stackshot
    (lib/machinespost.py) and `sala machines --json` carries as `not_read`. The one reader; nothing else builds the list."""
    p = paths(fleet_names, follow)
    for k, v in (("candidates", candidates), ("ssh", ssh), ("holds", holds)):
        if v is not None:
            p[k] = _path(v)
    return _list(p)


def _list(p: dict) -> tuple[list[dict], list[str]]:
    b = _Book()

    def seen(label: str, ok: bool, path) -> None:
        if not ok and path is not None:
            b.missed.append(label)

    # fleet-names.tsv: <os hostname> <fleet name> <letter>; the retired comment reserves a letter
    lines = _lines(p.get("fleet_names"))
    seen(NAMES_FILE, lines is not None, p.get("fleet_names"))
    for ln in lines or []:
        if not ln.strip():
            continue
        if ln.startswith("#"):
            m = _RETIRED.match(ln)
            if m:
                e = b.get(m.group(2), NAMES_FILE)
                e["letter"], e["retired"] = e["letter"] or m.group(1), True
            continue
        c = [x.strip() for x in ln.split("\t")]   # tab-separated, as the shell side and the web tab read it
        if len(c) < 3 or not c[1]:
            continue
        e = b.get(c[1], NAMES_FILE)
        e["hostname"], e["letter"] = e["hostname"] or c[0], e["letter"] or c[2]
        if c[0]:
            b.alias.setdefault(c[0].lower(), c[1].lower())
    # a retired machine goes after the others: the order of the names file's rows, then the reserved letters
    order = [k for k, e in b.by.items() if not e["retired"]] + [k for k, e in b.by.items() if e["retired"]]
    b.by = {k: b.by[k] for k in order}

    # candidates.conf: `host <hostname> <ipv4> <ipv6>`
    lines = _lines(p.get("candidates"))
    seen(CANDIDATES_FILE, lines is not None, p.get("candidates"))
    for ln in lines or []:
        w = ln.split("#", 1)[0].split()
        if len(w) == 4 and w[0] == "host":
            e = b.get(w[1], CANDIDATES_FILE)
            e["hostname"] = e["hostname"] or w[1]
            e["addresses"] = [w[2], w[3]]

    # ssh/fleet.conf: `Host <alias> ...` (a pattern is no machine)
    lines = _lines(p.get("ssh"))
    seen(SSH_FILE, lines is not None, p.get("ssh"))
    for ln in lines or []:
        w = ln.split("#", 1)[0].split()
        if len(w) >= 2 and w[0].lower() == "host":
            for a in w[1:]:
                if not any(ch in a for ch in "*?!"):
                    e = b.get(a, SSH_FILE)
                    e["ssh"] = e["ssh"] or a

    # machine-holds.toml: the [[hosts]] records
    doc = _toml(p.get("holds"))
    seen(HOLDS_FILE, doc is not None, p.get("holds"))
    for h in (doc or {}).get("hosts", []) if isinstance((doc or {}).get("hosts", []), list) else []:
        if isinstance(h, dict) and isinstance(h.get("host"), str) and h["host"]:
            e = b.get(h["host"], HOLDS_FILE)
            e["hostname"] = e["hostname"] or h["host"]
            if h.get("role") in ROLES and h["role"] not in e["roles"]:
                e["roles"].append(h["role"])

    # machine-follow's machines.toml: [machines.<hostname>]
    doc = _toml(p.get("follow"))
    seen(FOLLOW_FILE, doc is not None, p.get("follow"))
    ms = (doc or {}).get("machines")
    for name in ms if isinstance(ms, dict) else []:
        e = b.get(str(name), FOLLOW_FILE)
        e["hostname"] = e["hostname"] or str(name)

    order = {n: i for i, n in enumerate((NAMES_FILE, CANDIDATES_FILE, SSH_FILE, HOLDS_FILE, FOLLOW_FILE))}
    out = []
    for e in b.by.values():
        e["sources"].sort(key=order.__getitem__)
        out.append({k: e[k] for k in KEYS})
    return out, b.missed


# ---- the readings: the tailnet's view of each machine, and the versions this box can read of itself ----------------------
def _run(cmd: list[str], timeout: float, env: dict | None = None) -> str | None:
    """A command's standard output when it exits 0 inside `timeout` seconds, else None. It runs in its own process group, which a timeout stops as a whole (by group id, never by name);
    a command that is not there, cannot be run or prints nothing gives None too. Standard input is closed and standard error dropped."""
    try:
        proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env, start_new_session=True, text=True, errors="replace")
    except (OSError, ValueError):
        return None
    try:
        out, _ = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            proc.communicate(timeout=5)
        except Exception:      # noqa: BLE001  — the group is gone; nothing more to wait for
            pass
        return None
    except Exception:          # noqa: BLE001
        return None
    return out if proc.returncode == 0 and out and out.strip() else None


def tailnet_status(timeout: float = TAILSCALE_TIMEOUT, binary: str = "tailscale") -> dict | None:
    """`tailscale status --json` as a dict; None when tailscale is not on the PATH, fails, takes longer than `timeout` or prints no JSON object."""
    path = shutil.which(binary)
    if not path:
        return None
    out = _run([path, "status", "--json"], timeout)
    if out is None:
        return None
    try:
        d = json.loads(out)
    except ValueError:
        return None
    return d if isinstance(d, dict) else None


def _epoch(v) -> int | None:
    """Epoch seconds of an RFC 3339 time (tailscale's LastSeen); None for anything else, and for the year-1 zero time tailscale writes for never."""
    if not isinstance(v, str) or not v.strip():
        return None
    try:
        dt = datetime.fromisoformat(v.strip())
        if dt.year < 1971 or dt.tzinfo is None:
            return None
        return int(dt.timestamp())
    except (ValueError, OverflowError, OSError):
        return None


def _node_names(node: dict) -> set[str]:
    """The names a tailnet node answers to, lower-cased: its HostName and the first label of its DNSName."""
    out = set()
    h = node.get("HostName")
    if isinstance(h, str) and h:
        out.add(h.lower())
    d = node.get("DNSName")
    if isinstance(d, str) and d.strip("."):
        out.add(d.strip(".").split(".")[0].lower())
    return out


def _row_names(m: dict) -> set[str]:
    """The names a machine entry answers to, lower-cased: its fleet name, OS hostname and ssh alias (never an address: some entries have none in the tailnet file)."""
    return {str(m.get(k)).lower() for k in ("name", "hostname", "ssh") if m.get(k)}


def cap_versions(d) -> dict:
    """`versions` as the contract has it: text to text, empty values dropped, at most MAX_VERSIONS entries (the first ones)."""
    out: dict[str, str] = {}
    if isinstance(d, dict):
        for k, v in d.items():
            if isinstance(k, str) and isinstance(v, str) and k and v and len(out) < MAX_VERSIONS:
                out[k] = v
    return out


def add_readings(machines: list[dict], status: dict | None, now: float, self_names=(), versions: dict | None = None) -> list[dict]:
    """The entries, each with the four reading keys (READING_KEYS) after its own. `status` is `tailscale status --json` as a dict (None = no reading: every online and last_seen null);
    `self_names` are the names this box goes by (a row that answers to one of them, or to the tailnet's own Self node, is this box); `versions` is what this box read about itself, given to
    that row only (every other row gets {}). A row no tailnet node answers to has online and last_seen null: nothing is guessed. The entries given are not changed."""
    me = {n.lower() for n in self_names if isinstance(n, str) and n}
    peers: list[tuple[set[str], dict]] = []
    self_node = None
    if isinstance(status, dict):
        s = status.get("Self")
        if isinstance(s, dict):
            self_node = s
            me |= _node_names(s)
        pr = status.get("Peer")
        if isinstance(pr, dict):
            peers = [(_node_names(n), n) for n in pr.values() if isinstance(n, dict)]
    mine = cap_versions(versions)
    checked = int(now)
    out = []
    for m in machines:
        names = _row_names(m)
        online = last_seen = None
        vers: dict = {}
        if names & me:
            vers = dict(mine)
            if self_node is not None:      # the tailnet answered, and this box is the one asking
                o = self_node.get("Online")
                online = o if isinstance(o, bool) else True
        else:
            hits = [n for ns, n in peers if ns & names]
            if hits:
                # a machine registered twice (a stale node): an online one wins, else the one seen last
                hits.sort(key=lambda n: (n.get("Online") is True, _epoch(n.get("LastSeen")) or 0), reverse=True)
                n = hits[0]
                if isinstance(n.get("Online"), bool):
                    online = n["Online"]
                    last_seen = None if online else _epoch(n.get("LastSeen"))
        out.append(dict(m, online=online, last_seen=last_seen, versions=vers, checked=checked))
    return out


def claude_version(binary: str | None = None, timeout: float = 10) -> str:
    """The first word of `claude --version` ("" when it cannot be run): this box's CLI version."""
    out = _run([shutil.which(binary or "claude") or (binary or "claude"), "--version"], timeout)
    return out.split()[0] if out and out.split() else ""


def sala_commit(root: str | Path | None = None) -> str:
    """The short commit of the sala checkout `lib/` lives in ("" when it is not a git checkout or git cannot be run)."""
    root = Path(root) if root else Path(__file__).resolve().parent.parent
    out = _run(["git", "-C", str(root), "rev-parse", "--short", "HEAD"], 5, dict(os.environ, GIT_OPTIONAL_LOCKS="0"))
    return out.split()[0] if out and out.split() else ""


def self_names(name: str | None = None) -> list[str]:
    """The names this box goes by: the caller's own (the heartbeat's fleet name), the OS hostname and its first label."""
    out = [name] if name else []
    try:
        h = socket.gethostname()
    except OSError:
        h = ""
    if h:
        out += [h, h.split(".")[0]]
    return out


def read_with_readings(fleet_names=None, follow=None, *, candidates=None, ssh=None, holds=None, now: float | None = None, claude: str | None = None,
                       name: str | None = None, root=None, tailscale_timeout: float = TAILSCALE_TIMEOUT) -> tuple[list[dict], list[str]]:
    """`read_list` with the four reading keys on each entry (add_readings): the tailnet's status read once, and this box's own versions on the row that is this box (`claude` is its CLI version,
    empty or None leaves that key out; `sala` is the short commit of the checkout `root`, default the one this file is in). `name` is the fleet name this box goes by, when the caller knows it
    (the heartbeat does). Never raises for a missing tool or file. This is the list the heartbeat posts and `sala machines --json` prints."""
    machines, missed = read_list(fleet_names, follow, candidates=candidates, ssh=ssh, holds=holds)
    if not machines:
        return machines, missed
    versions = {}
    if claude:
        versions["claude"] = claude
    commit = sala_commit(root)
    if commit:
        versions["sala"] = commit
    now = time.time() if now is None else now
    return add_readings(machines, tailnet_status(tailscale_timeout), now, self_names(name), versions), missed


# ---- the CLI verbs -----------------------------------------------------------------------------------------------------
def _env_paths() -> dict[str, Path | None]:
    return paths(os.environ.get("SALA_FLEET_NAMES"), os.environ.get("SALA_MACHINE_FOLLOW_MACHINES"))


def _cell(v) -> str:
    return v if v else "-"


def cmd_list(argv: list[str]) -> int:
    as_json = False
    for a in argv:
        if a == "--json":
            as_json = True
        else:
            print("sala machines: unknown argument '%s' (see sala machines --help)" % a, file=sys.stderr)
            return 2
    p = _env_paths()
    if not any(p.get(k) for k in ("fleet_names", "follow")):
        print("sala machines: no machine files are named: set SALA_FLEET_NAMES (the fleet names file; the other files are looked for beside it) in sala's config", file=sys.stderr)
        return 2
    if as_json:   # the list the heartbeat posts: the entries and, on each, the tailnet's reading and this box's versions
        machines, missed = read_with_readings(p.get("fleet_names"), p.get("follow"), candidates=p.get("candidates"), ssh=p.get("ssh"), holds=p.get("holds"),
                                              claude=claude_version(os.environ.get("SALA_CLAUDE") or None))
        print(json.dumps({"schema": SCHEMA, "machines": machines, "not_read": missed}, indent=2))
        return 0
    machines, missed = _list(p)
    rows = [("NAME", "LETTER", "HOSTNAME", "SSH", "ROLES", "STATE", "FROM")]
    for m in machines:
        rows.append((m["name"], _cell(m["letter"]), _cell(m["hostname"]), _cell(m["ssh"]), _cell(",".join(m["roles"])), "retired" if m["retired"] else "-", ",".join(m["sources"])))
    w = [max(len(r[i]) for r in rows) for i in range(len(rows[0]) - 1)]
    for r in rows:
        print("  ".join(r[i].ljust(w[i]) for i in range(len(w))) + "  " + r[-1])
    if missed:
        print("not read: " + ", ".join(missed))
    return 0


def script_path() -> Path | None:
    return paths(os.environ.get("SALA_FLEET_NAMES"), os.environ.get("SALA_MACHINE_FOLLOW_MACHINES")).get("script")


def cmd_host(argv: list[str]) -> int:
    """`host ROLE [--field F]` and `host ROLE --set HOST`: the holds script's `host` and `set-host`, run as they are. Its output goes straight to ours and its exit
    code is ours, so a refusal reads and exits exactly as the script's own; nothing here locks or writes."""
    role = field = new = None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("--field", "--set"):
            if i + 1 >= len(argv):
                print("sala host: %s needs a value (see sala host --help)" % a, file=sys.stderr)
                return 2
            if a == "--field":
                field = argv[i + 1]
            else:
                new = argv[i + 1]
            i += 2
        elif a.startswith("-") or role is not None:
            print("sala host: unexpected argument '%s' (see sala host --help)" % a, file=sys.stderr)
            return 2
        else:
            role = a
            i += 1
    if role is None or (field is not None and new is not None):
        print("usage: sala host ROLE [--field FIELD | --set HOST]  (see sala host --help)", file=sys.stderr)
        return 2
    script = script_path()
    if script is None or not script.is_file():
        print("sala host: the holds script is not there%s: it is looked for under the folder of SALA_FLEET_NAMES (%s)" % (" (SALA_FLEET_NAMES is not set)" if script is None else "", LAYOUT["script"]), file=sys.stderr)
        return 2
    args = ["set-host", role, new] if new is not None else ["host", role] + (["--field", field] if field is not None else [])
    env = dict(os.environ)
    q = _env_paths()   # the two files the script lets the environment move are the ones `sala machines` reads: the same, always
    for var, key in (("MACHINE_HOLDS_TOML", "holds"), ("MACHINE_HOLDS_CANDIDATES", "candidates")):
        if q.get(key):
            env[var] = str(q[key])
    sys.stdout.flush()
    try:
        return subprocess.run([sys.executable, str(script)] + args, env=env, check=False).returncode
    except OSError as e:
        print("sala host: cannot run the holds script: %s" % e, file=sys.stderr)
        return 2


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    verb = argv.pop(0) if argv else ""
    if verb == "list":
        return cmd_list(argv)
    if verb == "host":
        return cmd_host(argv)
    print("usage: machines.py list [--json] | host ROLE [--field F | --set HOST]", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
