"""The New session form's project step: the calls to
stackshot's project API that the form makes before it queues the spawn.

The form picks a scope (one of this box's scopes, scopes.py, or `all` to look across them), then one project in it. What it asks stackshot, with this machine's client
token and server address (the files the board items read, board.py; nothing new is kept anywhere, and neither the token nor
the address reaches a page, a log or an error text):

  GET  /client/projects?scope=S[&q=Q]     the listed projects of the scope (S may be `all`: every scope's, each row with its own
                                          `scope`); with a query, the hidden matches too. Each row carries the page's `type`; the
                                          form keeps only the rows whose type is `project` (clean_projects), the one field that
                                          says what a registered project is
  POST /client/project                    {key, scope, title?, sender}: a new project and its gbrain page (minutes on a slow gbrain)
  POST /client/project-list               {key, scope?, sender}: a hidden project listed again
  POST /client/project-agent              {project, name, role, front, mandate, sender}: the agent added to the project

These are the same calls as `client.py get projects`, `post project`, `post project-list` and `post project-agent`
(~/stackshot/client.py), made over HTTP the way board.py reads the items. The one sender label is `sala-web`: stackshot lets
the label that made or listed a project within the hour add its first agents, since the form has no session of its own.

Every value is checked here against the shapes stackshot checks, so a bad one is a 400 here and never a request; nothing is
passed to a shell (there is none: these are HTTP calls with a JSON body). A new project's page can take minutes, which a
tunnel in front of this app would cut off at 100 s, so `post project` runs as a job: the page starts it, gets a job id and
asks for its state every few seconds (`Jobs`). The job's answer is kept in memory for an hour.
"""

from __future__ import annotations

import json
import re
import secrets
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from . import board as B
from . import scopes as SC
from . import spawn as SP

ALL = "all"                               # a view, not a scope: the list query alone takes it; never a project's scope
RETIRED_STATUSES = ("archived", "retired")
PROJECT_TYPE = "project"                  # the page `type` that makes a page a registered project
SENDER = "sala-web"                       # the one label of the form (spawn.FROM is the same word)
Q_MAX = 200
TITLE_MAX = 120
SLUG_MAX = 60
SLUG_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
PROJECT_ID_RE = re.compile(r"^prj_[0-9a-f]{8}$")
ROLE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$")
MANDATE_LINE_MAX = 600
JOB_RE = re.compile(r"^[0-9a-f]{16}$")
TIMEOUT_GET = 20.0
TIMEOUT_LIST = 30.0
TIMEOUT_AGENT = 30.0
TIMEOUT_NEW = 305.0                       # stackshot's own client waits 300 s for the gbrain write
JOB_KEEP = 3600.0
JOB_MAX = 20


# ── the shapes ───────────────────────────────────────────────────────────────
def scope_ok(scope: object) -> bool:
    """A project's scope: one of this box's scopes (scopes.py: SALA_SCOPES, else stackshot's list); when none is configured here,
    any scope-shaped name, stackshot being the one that knows its own."""
    names = SC.names()
    return scope in names if names else SC.valid_shape(scope)


def scope_message(extra: tuple[str, ...] = ()) -> str:
    names = SC.names()
    if names:
        return f"scope must be one of {', '.join((*names, *extra))}"
    return "scope must be lowercase letters, digits and dashes" + (f", or {', '.join(extra)}" if extra else "")


def one_line(text: object) -> bool:
    return isinstance(text, str) and not any(ord(c) < 32 or ord(c) == 127 for c in text)


def new_key_ok(key: object, dirs: list[str]) -> bool:
    """`post project --key`: `<dir>/<slug>`, one level, the dir one of the page dirs, the slug lowercase letters, digits and
    dashes (stackshot: at most 60)."""
    if not isinstance(key, str) or key.count("/") != 1:
        return False
    head, slug = key.split("/")
    return head in dirs and bool(SLUG_RE.match(slug)) and len(slug) <= SLUG_MAX


def project_ref_ok(ref: object, dirs: list[str]) -> bool:
    """A project named by its id (`prj_<8 hex>`) or its page key (any depth: stackshot refuses a sub-page itself)."""
    return isinstance(ref, str) and (bool(PROJECT_ID_RE.match(ref)) or SP.page_key_ok(ref, dirs))


def title_ok(title: object) -> bool:
    """stackshot's title: one line of at most 120 characters, no quotation marks or backslashes."""
    return isinstance(title, str) and len(title) <= TITLE_MAX and one_line(title) and '"' not in title and "\\" not in title


def validate_query(params: dict) -> tuple[str, str] | tuple[int, str]:
    scope = (params.get("scope") or "").strip().lower()
    q = (params.get("q") or "").strip()
    if scope != ALL and not scope_ok(scope):
        return 400, scope_message((ALL,))
    if len(q) > Q_MAX or not one_line(q):
        return 400, f"q is one line of at most {Q_MAX} characters"
    return scope, q


def validate_new(body: object, dirs: list[str]) -> dict | tuple[int, str]:
    if not isinstance(body, dict):
        return 400, "the body must be a JSON object"
    if set(body) - {"key", "scope", "title"}:
        return 400, "unknown fields: " + ", ".join(sorted(set(body) - {"key", "scope", "title"}))
    key, scope, title = body.get("key"), body.get("scope"), body.get("title")
    if not scope_ok(scope):
        return 400, scope_message()
    if not new_key_ok(key, dirs):
        return 400, f"key must be <dir>/<slug>, the dir one of {', '.join(dirs)}, the slug lowercase letters, digits and dashes, at most {SLUG_MAX} characters"
    out = {"key": key, "scope": scope, "sender": SENDER}
    if title not in (None, ""):
        title = " ".join(str(title).split()) if isinstance(title, str) else title
        if not title_ok(title):
            return 400, f"title is one line of at most {TITLE_MAX} characters with no quotation marks or backslashes"
        out["title"] = title
    return out


def validate_list(body: object, dirs: list[str]) -> dict | tuple[int, str]:
    if not isinstance(body, dict):
        return 400, "the body must be a JSON object"
    if set(body) - {"key", "scope"}:
        return 400, "unknown fields: " + ", ".join(sorted(set(body) - {"key", "scope"}))
    key, scope = body.get("key"), body.get("scope")
    if not project_ref_ok(key, dirs):
        return 400, "key must be a project id (prj_xxxxxxxx) or a page key (<dir>/<slug>)"
    out = {"key": key, "sender": SENDER}
    if scope not in (None, ""):
        if not scope_ok(scope):
            return 400, scope_message()
        out["scope"] = scope
    return out


def validate_agent(body: object, dirs: list[str]) -> dict | tuple[int, str]:
    if not isinstance(body, dict):
        return 400, "the body must be a JSON object"
    allowed = {"project", "name", "role", "front", "mandate"}
    if set(body) - allowed:
        return 400, "unknown fields: " + ", ".join(sorted(set(body) - allowed))
    project, name, role, front, mandate = (body.get(k) for k in ("project", "name", "role", "front", "mandate"))
    if not project_ref_ok(project, dirs):
        return 400, "project must be a project id (prj_xxxxxxxx) or a page key (<dir>/<slug>)"
    if not SP.name_ok(name):
        return 400, f"name must be lowercase letters, digits and dashes, no dash at either end, at most {SP.NAME_MAX} characters"
    if not isinstance(role, str) or not ROLE_RE.match(role):
        return 400, "role is the name's suffix after the project's name: letters, digits, dots, dashes and underscores, at most 32 characters"
    if not isinstance(front, bool):
        return 400, "front must be true (a front agent) or false (a background agent)"
    if not isinstance(mandate, str) or not mandate.strip():
        return 400, "mandate is the agent's one line for the page"
    line = " ".join(mandate.split())   # line breaks and tabs become spaces; any other control character is refused (stackshot does too)
    if not one_line(line):
        return 400, "mandate has a control character"
    if len(line) > MANDATE_LINE_MAX:
        return 400, f"mandate is one line of at most {MANDATE_LINE_MAX} characters"
    return {"project": project, "name": name, "role": role, "front": front, "mandate": line, "sender": SENDER}


# ── the stackshot calls ──────────────────────────────────────────────────────
class Reply:
    """What stackshot answered: the HTTP status (0 = not reached, -1 = this machine has no usable setup) and its JSON
    (a dict) or text."""

    def __init__(self, status: int, data: object):
        self.status, self.data = status, data

    @property
    def error(self) -> str:
        d = self.data
        if isinstance(d, dict) and d.get("error"):
            return str(d["error"])[:1200]
        return str(d or "")[:400]


def _request(token_path: Path, url_path: Path, method: str, path: str, query: dict | None, body: dict | None, timeout: float) -> Reply:
    """One call, blocking (run it in a thread). Never raises; carries neither the token nor the address in anything it returns."""
    try:
        token, base = B.read_token(token_path), B.read_url(url_path)
    except B.ConfigError as e:
        return Reply(-1, {"error": str(e)})
    url = f"{base}/client/{path}" + ("?" + urllib.parse.urlencode(query) if query else "")
    headers = {"Authorization": f"Bearer {token}", "User-Agent": "sala-web"}
    data = None
    if body is not None:
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers=headers)

    def dec(raw: bytes) -> object:
        try:
            return json.loads(raw.decode("utf-8", "replace"))
        except ValueError:
            return raw.decode("utf-8", "replace")[:600]

    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return Reply(r.status, dec(r.read()))
    except urllib.error.HTTPError as e:
        return Reply(e.code, dec(e.read()))
    except urllib.error.URLError as e:
        return Reply(0, {"error": f"stackshot unreachable ({str(e.reason)[:80]})"})
    except (TimeoutError, OSError) as e:
        return Reply(0, {"error": f"stackshot did not answer in time ({type(e).__name__})"})


class Stackshot:
    """The four calls, made with this machine's token and address files."""

    def __init__(self, token_path: Path, url_path: Path):
        self.token_path, self.url_path = token_path, url_path

    def projects(self, scope: str, q: str) -> Reply:
        return _request(self.token_path, self.url_path, "GET", "projects", {"scope": scope, **({"q": q} if q else {})}, None, TIMEOUT_GET)

    def new_project(self, body: dict) -> Reply:
        return _request(self.token_path, self.url_path, "POST", "project", None, body, TIMEOUT_NEW)

    def list_project(self, body: dict) -> Reply:
        return _request(self.token_path, self.url_path, "POST", "project-list", None, body, TIMEOUT_LIST)

    def item_facts(self, store_id: str) -> Reply:
        """The client API's item-facts row of one item (status, owner, project), asked as the web UI ("sala-web")."""
        return _request(self.token_path, self.url_path, "GET", "item-facts", {"key": "sala-web", "ids": store_id}, None, TIMEOUT_GET)

    def add_agent(self, body: dict) -> Reply:
        return _request(self.token_path, self.url_path, "POST", "project-agent", None, body, TIMEOUT_AGENT)


# ── what the page gets ───────────────────────────────────────────────────────
def _agents(raw: object) -> dict:
    out: dict = {}
    if isinstance(raw, dict):
        for name, a in raw.items():
            if isinstance(name, str) and isinstance(a, dict):
                out[name] = {"front": a.get("front") is True, "role": str(a.get("role") or "")[:40], **({"page_owed": True} if a.get("page_owed") else {})}
    return out


def is_retired(p: dict) -> bool:
    """A row that says it is retired is no project to start a session in. Stackshot lists such pages today (`listed_by:
    items`) and is being asked to stop; if it ever marks them (`retired: true`, or `status: archived|retired`),
    they are dropped here too. Nothing else is filtered on a guess."""
    status = p.get("status")
    return p.get("retired") is True or (isinstance(status, str) and status.strip().lower() in RETIRED_STATUSES)


def clean_projects(data: object) -> dict | None:
    """The rows of `GET /client/projects` in the page's shape: only the fields the form uses, strings cut to a sane length,
    and only the rows whose `type` is `project`; None for an answer that is not the list."""
    if not isinstance(data, dict) or not isinstance(data.get("projects"), list):
        return None
    rows = []
    for p in data["projects"]:
        if not isinstance(p, dict) or not isinstance(p.get("key"), str):
            continue
        if is_retired(p) or str(p.get("type") or "").strip().lower() != PROJECT_TYPE:
            continue   # a note page, a sub-page or a row that names no type is no project to start a session in
        rows.append({"id": str(p.get("id") or "")[:20], "key": p["key"][:200], "title": str(p.get("title") or "")[:200],
                     "name": str(p.get("name") or "")[:200], "type": str(p.get("type") or "")[:20], "scope": str(p.get("scope") or "")[:20],
                     "listed": p.get("listed") is True, "hidden": p.get("hidden") is True, "keeper": str(p.get("keeper") or "")[:80],
                     "main": str(p.get("main") or "")[:80], "agents": _agents(p.get("agents"))})
    scopes = [s for s in data.get("scopes", []) if isinstance(s, str) and s != ALL] if isinstance(data.get("scopes"), list) else SC.names()
    return {"scope": str(data.get("scope") or ""), "q": str(data.get("q") or ""), "scopes": scopes, "projects": rows}


# stackshot's status → the page's `code`: what the form says depends on it, not on the words
CODES = {400: "bad", 401: "refused", 403: "not-allowed", 404: "not-found", 409: "exists", 502: "gbrain", 503: "busy", 0: "unreachable", -1: "config"}


def failure(rep: Reply, step: str) -> tuple[int, dict]:
    """(HTTP status, body) for a call stackshot refused or could not make. 409 from `post project` means the page exists; from
    `post project-agent` it means the name is taken (the code is the same, `exists`: the page words it by the step)."""
    code = CODES.get(rep.status, "error")
    if rep.status == 409 and "being made" in (rep.error or "").lower():
        code = "in-progress"   # stackshot is making this key right now (another request): not a duplicate page, a wait
    status = rep.status if rep.status in (400, 403, 404, 409, 502, 503) else 502
    if rep.status == 401:
        return 502, {"ok": False, "code": "refused", "step": step, "error": "stackshot refused this machine's token (HTTP 401)"}
    return status, {"ok": False, "code": code, "step": step, "error": rep.error or f"stackshot answered HTTP {rep.status}"}


def project_success(rep: Reply) -> dict:
    """The fields of a made, listed or agent-adding answer the page keeps: the project's id and key, whether the page still
    owes the agent's line (and the lines), and stackshot's note."""
    d = rep.data if isinstance(rep.data, dict) else {}
    proj = d.get("project")
    if isinstance(proj, dict):
        pid, key = proj.get("id"), proj.get("key")
    else:
        pid, key = proj, d.get("key")
    out = {"ok": True, "id": str(pid or "")[:20], "key": str(key or "")[:200], "note": str(d.get("note") or "")[:1200]}
    if "created" in d:
        out["created"] = d.get("created") is True
    if "changed" in d:
        out["changed"] = d.get("changed") is True
    if "page_owed" in d:
        out["pageOwed"] = d.get("page_owed") is True
    if d.get("page_yaml"):
        out["pageYaml"] = str(d["page_yaml"])[:2000]
    return out


# ── the job that makes a project ─────────────────────────────────────────────
class Jobs:
    """`post project` can take minutes, so the page starts it and asks for its state. One at a time (a second start while
    one runs is refused: the page disables its button, and two creates of one key would only fight); the answer stays for an
    hour. In memory: a restart of the app loses it, and the page then says so (the project may exist: the list shows it)."""

    def __init__(self):
        self._jobs: dict[str, dict] = {}

    def running(self) -> bool:
        return any(j["state"] == "running" for j in self._jobs.values())

    def _prune(self) -> None:
        now = time.time()
        for k in [k for k, j in self._jobs.items() if j["state"] != "running" and now - j["ended"] > JOB_KEEP]:
            del self._jobs[k]
        while len(self._jobs) >= JOB_MAX:
            old = min((k for k, j in self._jobs.items() if j["state"] != "running"), key=lambda k: self._jobs[k]["ended"], default=None)
            if old is None:
                break
            del self._jobs[old]

    def start(self, work) -> str:
        """`work` is a blocking callable returning (status, body); it runs in a thread."""
        self._prune()
        jid = secrets.token_hex(8)
        job = {"state": "running", "started": time.time(), "ended": 0.0, "status": 0, "body": None}
        self._jobs[jid] = job

        def run() -> None:
            try:
                status, body = work()
            except Exception as e:  # a bug here must still end the job, or the page waits for ever
                status, body = 500, {"ok": False, "code": "error", "error": f"could not make the project: {type(e).__name__}"}
            job.update(state="done", ended=time.time(), status=status, body=body)

        # a thread of its own, not a task of the request's loop: the call outlives the request that started it
        threading.Thread(target=run, name="sala-web-new-project", daemon=True).start()
        return jid

    def get(self, jid: str) -> dict | None:
        j = self._jobs.get(jid) if JOB_RE.match(jid) else None
        if j is None:
            return None
        out = {"state": j["state"], "elapsed": int((j["ended"] or time.time()) - j["started"])}
        if j["state"] == "done":
            out.update(status=j["status"], result=j["body"])
        return out
