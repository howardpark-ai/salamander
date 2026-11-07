"""Settings, from the environment (and the CLI flags in app.main, which override them).

Defaults follow the XDG base directories: the socket lives in $XDG_RUNTIME_DIR, uploads in $XDG_STATE_HOME, the
Anthropic Admin API key (the API spend card's) in $XDG_CONFIG_HOME/anthropic/admin-key and stackshot's client token and
server address (the board items') in $XDG_CONFIG_HOME/stackshot/, where stackshot's own client keeps them.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass, field
from pathlib import Path

from . import sentimages as SI


def sala_setting(name: str, default: str = "") -> str:
    """One sala setting, the way sala reads it: the process environment wins, else the line `NAME=value` in sala's config file
    ($SALA_CONFIG, default ~/.config/salamander/config; read as text, never sourced, so a quoted value, a trailing `# note`, an
    `export ` prefix and a leading $HOME or ~ are understood and nothing else is run), else `default`. sala-web has no sala
    environment of its own, so this is how a setting written once in sala's config reaches it."""
    v = os.environ.get(name)
    if v:
        return v
    path = os.environ.get("SALA_CONFIG") or str(Path.home() / ".config" / "salamander" / "config")
    found = ""
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                m = re.match(r"\s*(?:export\s+)?" + re.escape(name) + r"=(.*)$", line.rstrip("\n"))
                if m:
                    found = _config_value(m.group(1))   # the last assignment wins, as in a sourced file
    except (OSError, UnicodeDecodeError):
        return default
    return found or default


def _config_value(raw: str) -> str:
    raw = raw.strip()
    if raw[:1] in ("'", '"'):
        end = raw.find(raw[0], 1)
        val = raw[1:end] if end > 0 else raw[1:]
    else:
        val = re.split(r"\s+#", raw, maxsplit=1)[0].strip()
    home = str(Path.home())
    if val.startswith("~/") or val == "~":
        val = home + val[1:]
    return val.replace("${HOME}", home).replace("$HOME", home)


# The tmux session of the Shell drawer: a plain login bash on this box, never a Claude pane. It is not a Claude session, so
# every list, the registry and the revive logic ignore it. The name is sala's setting SALA_SHELL_SESSION (default sala-shell),
# read the same way sala reads it: from the environment, else from sala's config file. The web UI gets it from /api/config.
SHELL_SESSION = sala_setting("SALA_SHELL_SESSION", "sala-shell")


def brand_suffix() -> str:
    """What follows "salamander" in the page's title bar: sala's setting SALA_BRAND_SUFFIX, one line of at most 40 characters;
    "" (the default) shows "salamander" alone. Read on each call, so a changed config line shows at the next page load."""
    return " ".join(sala_setting("SALA_BRAND_SUFFIX").split())[:40]


def help_session() -> str:
    """The session the overview's Get Help chip opens: sala's setting SALA_HELP_SESSION, one session name (letters, digits, dot,
    underscore, dash; at most 64). "" (the default, and any other value) = the page shows no Get Help chip. Read on each call."""
    v = sala_setting("SALA_HELP_SESSION").strip()
    return v if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", v) else ""


def owner_name() -> str:
    """What the page's own text and the words it queues call the human running this machine: sala's setting SALA_OWNER_NAME
    (default "the owner"; one line of at most 40 characters). Read on each call, like brand_suffix."""
    return " ".join(sala_setting("SALA_OWNER_NAME").split())[:40] or "the owner"


def _runtime_dir() -> Path:
    v = os.environ.get("XDG_RUNTIME_DIR")
    return Path(v) if v else Path(f"/run/user/{os.getuid()}")


def _config_home() -> Path:
    v = os.environ.get("XDG_CONFIG_HOME")
    return Path(v) if v else Path.home() / ".config"


def _roles_cmd() -> list[str]:
    """The roles command: SALA_WEB_ROLES_CMD, else `python3 <stackshot dir>/client.py get roles`. The directory is sala's knob
    SALA_STACKSHOT_DIR (read from the environment, as every setting here): unset it is ~/stackshot, the same default
    every other stackshot command in sala uses; set empty there is no stackshot on this box and no command (the overview then
    says so in rolesError and shows the sessions without roles)."""
    explicit = os.environ.get("SALA_WEB_ROLES_CMD", "").split()
    if explicit:
        return explicit
    d = os.environ.get("SALA_STACKSHOT_DIR")
    if d is None:
        d = str(Path.home() / "stackshot")
    return ["python3", str(Path(d).expanduser() / "client.py"), "get", "roles"] if d else []


def _state_home() -> Path:
    v = os.environ.get("XDG_STATE_HOME")
    return Path(v) if v else Path.home() / ".local" / "state"


def _stackshot_toml() -> dict:
    """stackshot's own settings file, $XDG_CONFIG_HOME/stackshot/stackshot.toml, as a dict; {} when it is not there or does
    not parse. Read for where its pages checkout is and which directories hold pages (the New session form's project
    list comes from the same files stackshot's pages.py checks a key against)."""
    import tomllib
    try:
        with open(_config_home() / "stackshot" / "stackshot.toml", "rb") as f:
            return tomllib.load(f)
    except (OSError, ValueError):
        return {}


def _stackshot_web() -> str:
    """The board's web address, where an item's page is linked (<this>/items/<id>): SALA_WEB_STACKSHOT_WEB when the variable is
    set (empty means no link), else the board_url of stackshot's own settings file ([instance]), else "" (no link: the item is
    shown without one)."""
    v = os.environ.get("SALA_WEB_STACKSHOT_WEB")
    if v is None:
        v = (_stackshot_toml().get("instance") or {}).get("board_url") or ""
    return str(v).strip().rstrip("/")


def _brain_dir() -> Path | None:
    """The pages checkout (the brain mirror): SALA_WEB_BRAIN_DIR, else stackshot's own [paths] brain, else sala's setting
    SALA_BRAIN_DIR; None when none of them names one (the project list is then empty, with that reason)."""
    v = os.environ.get("SALA_WEB_BRAIN_DIR")
    if v:
        return Path(v).expanduser()
    brain = (_stackshot_toml().get("paths") or {}).get("brain") or sala_setting("SALA_BRAIN_DIR")
    return Path(str(brain)).expanduser() if brain else None


def _page_dirs() -> list[str]:
    v = os.environ.get("SALA_WEB_PAGE_DIRS")
    if v:
        return v.replace(",", " ").split()
    dirs = (_stackshot_toml().get("pages") or {}).get("dirs")
    if isinstance(dirs, list) and dirs and all(isinstance(d, str) and d for d in dirs):
        return list(dirs)
    return sala_setting("SALA_PAGE_DIRS", "projects").replace(",", " ").split() or ["projects"]   # sala's own line, default projects


def _stackshot_path(key: str) -> Path | None:
    """One path of stackshot's own settings file ([paths] `key`), with a leading ~ expanded; None when it names none."""
    v = (_stackshot_toml().get("paths") or {}).get(key)
    return Path(str(v)).expanduser() if v else None


def _stackshot_state() -> Path:
    """Where stackshot writes what it knows for itself (site/versions.json, clients/fleet/): SALA_WEB_STACKSHOT_STATE,
    else stackshot's own [paths] state, else $XDG_STATE_HOME/stackshot. The Machines tab reads these files and never writes them."""
    v = os.environ.get("SALA_WEB_STACKSHOT_STATE")
    return Path(v).expanduser() if v else (_stackshot_path("state") or _state_home() / "stackshot")


def _fleet_names_file() -> Path | None:
    """The fleet's names file (os hostname, fleet name, board letter): SALA_WEB_FLEET_NAMES, else stackshot's [paths] fleet_names; None for neither."""
    v = os.environ.get("SALA_WEB_FLEET_NAMES")
    return Path(v).expanduser() if v else _stackshot_path("fleet_names")


def _follow_machines_file() -> Path | None:
    """The list of machines that follow the coordinator (machine-follow's machines.toml): SALA_WEB_MACHINE_FOLLOW_MACHINES, else
    claude/machine-follow/machines.toml beside the folder that holds the fleet names file; None when neither names a place."""
    v = os.environ.get("SALA_WEB_MACHINE_FOLLOW_MACHINES")
    if v:
        return Path(v).expanduser()
    names = _fleet_names_file()
    return names.parent / "claude" / "machine-follow" / "machines.toml" if names else None


def _follow_state_dir() -> Path:
    """Where machine-follow records each machine's last follow (<host>.json): SALA_WEB_MACHINE_FOLLOW_STATE, else $XDG_STATE_HOME/machine-follow."""
    v = os.environ.get("SALA_WEB_MACHINE_FOLLOW_STATE")
    return Path(v).expanduser() if v else _state_home() / "machine-follow"


def _web_setting(name: str) -> str:
    """A path setting of the web UI's own: `name` in the environment, else `name` in sala's config file (sala_setting),
    else empty."""
    return os.environ.get(name) or sala_setting(name)


def _optional_path(name: str) -> Path | None:
    v = os.environ.get(name, "").strip()
    return Path(v) if v else None


@dataclass
class Settings:
    # SALA_WEB_SOCKET pins the socket path. Under socket activation the
    # path is the socket unit's ListenStream=, which install.sh --web writes from the same setting.
    socket: Path = field(default_factory=lambda: Path(
        _web_setting("SALA_WEB_SOCKET") or _runtime_dir() / "sala-web" / "sala-web.sock"))
    state_dir: Path = field(default_factory=lambda: Path(
        _web_setting("SALA_WEB_STATE_DIR") or _state_home() / "sala-web"))
    # THE OLD SOCKET PATHS, kept working for one release after the units were renamed (README, *Renamed units*): at start
    # each is made a symlink to the socket it stands for, when its parent directory exists. install.sh --web and deploy.sh
    # set them (a drop-in of sala-web.service) on an install that ran the units under their old name; unset = nothing.
    compat_socket: Path | None = field(default_factory=lambda: _optional_path("SALA_WEB_COMPAT_SOCKET"))
    compat_ttyd_socket: Path | None = field(default_factory=lambda: _optional_path("SALA_WEB_COMPAT_TTYD_SOCKET"))
    # where sala-web-ttyd.service listens (its --interface); the target of the old ttyd socket's link
    ttyd_socket: Path = field(default_factory=lambda: Path(
        os.environ.get("SALA_WEB_TTYD_SOCKET") or _runtime_dir() / "sala-web-ttyd" / "ttyd.sock"))
    claude_dir: Path = field(default_factory=lambda: Path(
        os.environ.get("SALA_WEB_CLAUDE_DIR") or Path.home() / ".claude"))
    # tmux -L <name>; empty means the default server. Tests point this at a private server.
    tmux_socket_name: str = field(default_factory=lambda: os.environ.get("SALA_WEB_TMUX_SOCKET", ""))
    roles_cmd: list[str] = field(default_factory=_roles_cmd)
    roles_ttl: float = 30.0
    # sala's record of the model and effort a session is relaunched on (salamander lib/common.sh "models"): one
    # "<tmux session>\t<model>\t<effort or ->" row per session with a model of its own; read-only here
    sala_models: Path = field(default_factory=lambda: Path(
        os.environ.get("SALA_WEB_SALA_MODELS") or _state_home() / "salamander" / "models.tsv"))
    terminal_url: str = field(default_factory=lambda: os.environ.get(
        "SALA_WEB_TERMINAL_URL", "/tty/?arg="))  # ttyd behind the same host and Access app
    max_upload_bytes: int = 20 * 1024 * 1024   # an image
    # any other file: streamed to disk, refused past this size or when it would leave under min_free_bytes free
    max_file_upload_bytes: int = 500 * 1024 * 1024
    min_free_bytes: int = 2 * 1024 * 1024 * 1024
    # the places an image a session sends (SendUserFile) may be read from, and its size cap (sentimages.py): the home
    # directory and Claude Code's scratch directory /tmp/claude-<uid>; SALA_WEB_IMAGE_ROOTS overrides with a
    # colon-separated list (the tests point it at a temporary directory)
    image_roots: list[Path] = field(default_factory=lambda: (
        [Path(p) for p in os.environ["SALA_WEB_IMAGE_ROOTS"].split(":") if p] if os.environ.get("SALA_WEB_IMAGE_ROOTS")
        else SI.default_roots()))
    max_sent_image_bytes: int = SI.MAX_BYTES
    # the API spend card (metered and sdk lanes) reads the Admin API with this key. The promotional credit's anchor
    # file (sala-web/credit.json, SALA_WEB_CREDIT_CONFIG) is no longer read
    admin_key: Path = field(default_factory=lambda: Path(
        os.environ.get("SALA_WEB_ADMIN_KEY") or _config_home() / "anthropic" / "admin-key"))
    # THE BOARD: each session's open stackshot items, read from stackshot's client API with this machine's
    # token (board.py). The files are stackshot's own, as its client.py reads them (the same user as sala-web): the token
    # is read at each refresh and only ever sent as the Authorization header; the address file holds the server's URL
    # (STACKSHOT_URL in the environment overrides it, as for stackshot's client). The web address is where an item's
    # page is linked (/items/<id>).
    stackshot_token: Path = field(default_factory=lambda: Path(
        os.environ.get("SALA_WEB_STACKSHOT_TOKEN") or _config_home() / "stackshot" / "client.token"))
    stackshot_url: Path = field(default_factory=lambda: Path(
        os.environ.get("SALA_WEB_STACKSHOT_URL") or _config_home() / "stackshot" / "client.url"))
    stackshot_web: str = field(default_factory=_stackshot_web)
    # THE NEW SESSION FORM (spawn.py): the one write to sala. `sala op spawn …` is run as an argv list (the
    # program found on PATH, else sala's own install places); the project list is read from the pages under stackshot's
    # pages checkout (stackshot.toml [paths] brain, [pages] dirs; read-only, names and titles); the queued operation's state
    # from sala's own marker under its state directory (ops/<id>.op, read-only). The mandate files the form writes live
    # under state_dir/mandates/.
    sala_cmd: list[str] = field(default_factory=lambda: os.environ.get("SALA_WEB_SALA_CMD", "").split() or ["sala"])
    sala_state_dir: Path = field(default_factory=lambda: Path(
        os.environ.get("SALA_WEB_SALA_STATE") or _state_home() / "salamander"))
    brain_dir: Path | None = field(default_factory=_brain_dir)
    page_dirs: list[str] = field(default_factory=_page_dirs)
    # THE MACHINES TAB (machines.py): files other programs write, read-only here. stackshot's state folder holds the machines'
    # versions; the fleet names file and machine-follow's list and records say which machines there are and how each
    # one stays current. Nothing is asked of GitHub, ssh or a machine: the tab shows the last reading, with its age.
    stackshot_state: Path = field(default_factory=_stackshot_state)
    fleet_names_file: Path | None = field(default_factory=_fleet_names_file)
    follow_machines_file: Path | None = field(default_factory=_follow_machines_file)
    follow_state_dir: Path = field(default_factory=_follow_state_dir)

    @property
    def uploads_dir(self) -> Path:
        return self.state_dir / "uploads"

    @property
    def mandates_dir(self) -> Path:
        return self.state_dir / "mandates"

    @property
    def sessions_dir(self) -> Path:
        return self.claude_dir / "sessions"

    @property
    def projects_dir(self) -> Path:
        return self.claude_dir / "projects"
