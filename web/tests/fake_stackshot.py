"""A stand-in for stackshot's client API (the project calls; the For you calls, below), for the New session form's tests: a real HTTP server on
127.0.0.1 that answers `GET /client/projects` and `POST /client/project | project-list | project-agent` the way stackshot's
route does (the shapes in stackshot's client API), keeps what it was asked, and can be told to be slow or to
refuse. Nothing here reaches the real stackshot, a gbrain or the network: the app under test gets its token and address
from two files in a temporary directory (the files board.py reads) and the server only ever answers a bearer token it made
up. `FakeStackshot.requests` holds method, path, query and JSON body of every call, never the token."""

from __future__ import annotations

import json
import re
import secrets
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlsplit

SCOPES = ["beta", "gamma", "example"]
COMBO_KEYS = ("bg", "card", "fg", "mut", "line", "ibd", "link", "solid", "onsolid", "labbg", "labfg", "labbd", "disbg", "disfg")
COMBOS_MAX = 50


def row(key: str, title: str, scope: str, *, listed: bool = True, type_: str = "project", agents: dict | None = None, keeper: str = "", **extra) -> dict:
    """`extra`: fields stackshot may add to a row (`retired`, `status`)."""
    agents = agents or {}
    main = next((n for n, a in sorted(agents.items()) if a.get("front") and n.endswith("-main")), "")
    return {**extra, "id": "prj_" + secrets.token_hex(4), "key": key, "title": title, "name": title, "scope": scope, "listed": listed, "hidden": not listed,
            "listed_by": "agents" if agents else ("on_purpose" if listed else ""), "type": type_, "hub": "", "keeper": keeper, "main": main,
            "agents": agents, "items_30d": 0}


def agent(front: bool = True, role: str = "main", line: str = "the project's main agent") -> dict:
    return {"front": front, "role": role, "mandate_line": line}


def foryou_row(rid: int, kind: str, item: str, what: str, *, project: str = "projects/gamma-sala", urgent: bool = False, when: str = "5 min ago",
               slacked: bool = False, ts: float = 1792800000.0) -> dict:
    """One entry of stackshot's For you list, in the shape of `GET /client/for-you` (foryou.py is the one place that reads it)."""
    return {"id": rid, "kind": kind, "item": item, "project": project, "what": what, "url": f"https://board.example.test/items/{item.split('#')[-1]}" if item else "",
            "urgent": urgent, "ts": ts, "when": when, "slacked": slacked}


def default_foryou() -> list[dict]:
    return [
        foryou_row(41, "decision", "board#35", "Needs your decision: show For you in the items sheet", urgent=True, when="2 min ago"),
        foryou_row(40, "closed", "board#37", "Closed: AWS spend cards", project="projects/demo", when="1 h ago", slacked=True),
        foryou_row(39, "check_failed", "board#36", "A check failed on the write-up recorder", project="projects/stackshot", when="3 h ago"),
        foryou_row(38, "release_failed", "", "A release of stackshot failed to deploy", project="projects/stackshot", urgent=True, when="yesterday"),
    ]


def default_rows() -> list[dict]:
    return [
        row("projects/beta-web", "BETA web", "beta", agents={"beta-web-main": agent()}, keeper="beta-web-main"),
        row("projects/beta-docs", "BETA docs", "beta"),
        row("projects/gamma-harbor", "Harbor planning", "gamma", agents={"gamma-harbor-main": agent()}, keeper="gamma-harbor-main"),
        row("projects/gamma-pantry", "Pantry", "gamma"),
        row("projects/stackshot", "stackshot", "example", agents={"board-main": agent(), "demo-builder": agent(False, "engineer", "builds")}),
        row("projects/demo", "demo", "example", agents={"demo-main": agent()}, keeper="demo-main"),
        # hidden: the scope's pages that are listed only when a query matches them
        row("projects/gamma-old-kayak", "Old kayak planning", "gamma", listed=False),
        row("projects/gamma-kayak-notes", "Kayak notes", "gamma", listed=False, type_="note"),
        row("projects/gamma-pantry-2019", "Pantry 2019", "gamma", listed=False),
        row("projects/beta-api", "BETA api", "beta", listed=False),
        row("projects/old-box", "An old box", "example", listed=False),
    ]


def retired_rows() -> list[dict]:
    """Retired projects as stackshot lists them today (`listed_by: items`), and with the marks it may add: the form must not
    offer any of them (projects/widget and projects/bench-blog are `status: archived`)."""
    unmarked = row("projects/gamma-widget", "Widget", "gamma")            # no mark yet: stackshot still lists it, and so does the form
    unmarked["listed_by"] = "items"
    return [unmarked,
            row("projects/gamma-bench-blog", "Bench blog", "gamma", status="archived"),
            row("projects/beta-old-web", "Old web", "beta", status="Retired"),
            row("projects/example-gone", "Gone", "example", retired=True),
            row("projects/gamma-hidden-gone", "Hidden and gone", "gamma", listed=False, status="archived")]


class FakeStackshot:
    def __init__(self, cfg_dir: Path):
        self.token = "fake-" + secrets.token_hex(12)
        self.rows = default_rows()
        self.requests: list[dict] = []
        self.new_delay = 0.0
        self.new_reply: tuple[int, dict] | None = None      # a forced answer for `post project`
        self.list_reply: tuple[int, dict] | None = None
        self.agent_reply: tuple[int, dict] | None = None
        self.pending_names: set[str] = set()   # names held by a pending entry from another sender
        self.projects_reply: tuple[int, object] | None = None
        self.agent_page_owed = True
        # For you: the unseen entries newest first, the flags, the items stackshot knows, and forced answers
        self.foryou = default_foryou()
        self.flags: dict[str, str] = {}
        self.known_items = {"board#35", "board#37", "board#36", "board#12"}
        self.seen_ids: set[int] = set()
        self.foryou_reply: tuple[int, object] | None = None
        self.seen_reply: tuple[int, object] | None = None
        self.watch_reply: tuple[int, object] | None = None
        self.foryou_delay = 0.0
        # Side conversations: `GET /client/item-facts?ids=<store id,…>` as the client API answers it; an unknown id is left out
        self.item_facts = {"g38": {"status": "open", "shown": "board#38", "owner": "demo-builder", "mine": False, "agent": False, "project": "projects/demo"},
                           "s9": {"status": "open", "shown": "s9", "owner": "", "mine": False, "agent": False, "project": "projects/gamma-harbor"},
                           "l3": {"status": "closed", "shown": "board-tmp-box#3", "owner": "Alex Rivera", "mine": False, "agent": False, "project": "projects/beta-web"}}
        # saved color combinations (the color tool): the one list, a forced answer, a 413 switch and the "saved" clock
        self.combos: list[dict] = []
        self.combos_reply: tuple[int, object] | None = None
        self.combos_too_big = False
        self.combo_clock = 1792800000
        self.seen_without_rows = False     # answer a seen call without `rows` (a shape tolerance)
        self.watch_without_flags = False
        self._lock = threading.Lock()
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *a):  # silence
                pass

            def _send(self, status: int, body: object) -> None:
                raw = body.encode() if isinstance(body, str) else json.dumps(body, ensure_ascii=False).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "text/plain" if isinstance(body, str) else "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def _auth(self) -> bool:
                if self.headers.get("Authorization") != f"Bearer {outer.token}":
                    self._send(401, "unauthorized")
                    return False
                return True

            def do_GET(self):
                u = urlsplit(self.path)
                if not self._auth():
                    return
                q = {k: v[0] for k, v in parse_qs(u.query).items()}
                outer.requests.append({"method": "GET", "path": u.path, "query": q})
                if u.path == "/client/for-you":
                    if outer.foryou_delay:
                        time.sleep(outer.foryou_delay)
                    if outer.foryou_reply:
                        return self._send(*outer.foryou_reply)
                    with outer._lock:
                        return self._send(200, {"generated": "2026-10-24T00:00:00Z", "rows": list(outer.foryou), "flags": dict(outer.flags)})
                if u.path == "/client/item-facts":
                    ids = [i for i in q.get("ids", "").split(",") if i]
                    return self._send(200, {"items": {i: outer.item_facts[i] for i in ids if i in outer.item_facts}})
                if u.path == "/client/colors/combos":
                    with outer._lock:
                        return self._send(*outer._combos_reply(None))
                if u.path != "/client/projects":
                    return self._send(404, "no such read")
                if outer.projects_reply:
                    return self._send(*outer.projects_reply)
                scope, text = q.get("scope", ""), q.get("q", "").lower()
                if scope not in SCOPES + ["all"]:
                    return self._send(400, "scope = beta | gamma | example | all")
                with outer._lock:
                    rows = [r for r in outer.rows if scope == "all" or r["scope"] == scope]
                    shown = sorted((r for r in rows if r["listed"]), key=lambda r: r["key"])
                    hidden = sorted((r for r in rows if not r["listed"] and text and any(text in x.lower() for x in (r["key"], r["name"], r["title"]))), key=lambda r: r["key"])
                self._send(200, {"scope": scope, "q": q.get("q", ""), "generated": "2026-10-24T00:00:00Z", "scopes": SCOPES, "projects": shown + hidden})

            def do_POST(self):
                u = urlsplit(self.path)
                if not self._auth():
                    return
                n = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(n) or b"{}")
                outer.requests.append({"method": "POST", "path": u.path, "body": body})
                with outer._lock:
                    status, out = outer._post(u.path, body)
                if u.path == "/client/project" and outer.new_delay:
                    time.sleep(outer.new_delay)
                self._send(status, out)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        cfg_dir.mkdir(parents=True, exist_ok=True)
        self.token_file, self.url_file = cfg_dir / "client.token", cfg_dir / "client.url"
        self.token_file.write_text(self.token + "\n")
        self.url_file.write_text(self.url + "\n")

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()

    def find(self, ref: str) -> dict | None:
        return next((r for r in self.rows if ref in (r["id"], r["key"], r["key"].rsplit("/", 1)[-1])), None)

    def calls(self, path: str) -> list[dict]:
        return [r for r in self.requests if r["path"] == path]

    def _post(self, path: str, b: dict) -> tuple[int, dict]:
        path = unquote(path)
        if path in ("/client/colors/combos", "/client/colors/combos/delete"):
            return self._combos_reply(b, path.endswith("/delete"))
        if path == "/client/for-you/seen":
            return self._seen(b)
        if path.startswith("/client/items/") and path.endswith("/watch"):
            return self._watch(path[len("/client/items/"):-len("/watch")], b)
        if path == "/client/project":
            if self.new_reply:
                return self.new_reply
            key = b.get("key", "")
            if self.find(key):
                return 409, {"error": f"{key} already exists: list it again with `client.py post project-list --key {key}`"}
            r = row(key, b.get("title") or key.rsplit("/", 1)[-1].capitalize(), b["scope"])
            r["_marked"] = b.get("sender") == "sala-web"
            self.rows.append(r)
            return 200, {"project": r, "created": True, "page": {"key": key, "state": "ok", "display_name": "x"}, "page_yaml": "",
                         "note": f"Made {key} ({r['id']}) in scope {b['scope']}"}
        if path == "/client/project-list":
            if self.list_reply:
                return self.list_reply
            r = self.find(b.get("key", ""))
            if not r:
                return 404, {"error": f"no project {b.get('key')!r}"}
            if r["type"] == "note":
                return 400, {"error": f"{r['key']} is a `type: note` page, and a note is never listed"}
            changed = not r["listed"]
            r["_marked"] = b.get("sender") == "sala-web"
            r["listed"], r["hidden"] = True, False
            return 200, {"project": r, "changed": changed, "note": "listed"}
        if path == "/client/project-agent":
            if self.agent_reply:
                return self.agent_reply
            r = self.find(b.get("project", ""))
            if not r:
                return 404, {"error": f"no project {b.get('project')!r}"}
            # stackshot: sala-web may add an agent to ANY listed project, one with agents already included; 403 a retired or
            # hidden project, 409 a name that another project's agent holds or that is pending from another sender
            if r.get("retired") or not r["listed"] or str(r.get("status", "")).lower() in ("archived", "retired"):
                return 403, {"error": f"{r['key']} is retired or hidden: list it again first"}
            if any(b["name"] in o["agents"] for o in self.rows if o is not r) or b["name"] in self.pending_names:
                return 409, {"error": f"{b['name']} is already taken (another project's agent, or pending from another sender)"}
            had_agents = bool(r["agents"])
            r["agents"][b["name"]] = {"front": b["front"], "role": b["role"], "mandate_line": b["mandate"], "page_owed": True}
            # stackshot: entries only, no `agents:` header, when the page has an agents map already (the note says which)
            if had_agents:
                page_yaml, how = f"  {b['name']}: {b['mandate']}\n", "Add these entries under the page's existing agents: map."
            else:
                page_yaml, how = f"agents:\n  {b['name']}: {b['mandate']}\n", "The page has no agents: map yet; add this block."
            return 200, {"project": r["id"], "key": r["key"], "agent": {b["name"]: r["agents"][b["name"]]}, "page_owed": self.agent_page_owed,
                         "page_yaml": page_yaml, "note": "Recorded in stackshot's record only: the page line is still owed. " + how}
        return 404, {"error": "no such write"}

    # ── saved color combinations: stackshot's three routes the color tool uses ───────────
    def _combos_out(self) -> tuple[int, object]:
        return 200, {"combos": [dict(c) if isinstance(c, dict) else c for c in self.combos], "max": COMBOS_MAX}

    def _combos_reply(self, b: dict | None, delete: bool = False) -> tuple[int, object]:
        """GET (b None) / POST save / POST delete, as stackshot answers them: 200 {combos, max}, or {error, field} with 400 (bad name,
        value or key set), 403 (sender not sala-web), 409 (list full), 413 (over 4 KB, set by `combos_too_big`), 503 (`combos_reply`
        forces any answer). A save under an existing name (case ignored) replaces it in place; an unknown id on delete is a 200."""
        if self.combos_reply:
            return self.combos_reply
        if b is None:
            return self._combos_out()
        if self.combos_too_big:
            return 413, {"error": "That request is over 4 KB.", "field": None}
        if b.get("sender") != "sala-web":
            return 403, {"error": f"The sender {b.get('sender')!r} may not change the saved list from here.", "field": "sender"}
        if delete:
            cid = b.get("id")
            if not isinstance(cid, str) or not cid:
                return 400, {"error": "id is the saved combination's id.", "field": "id"}
            self.combos = [c for c in self.combos if c["id"] != cid]
            return self._combos_out()
        name, vals = b.get("name"), b.get("values")
        if not isinstance(name, str) or not 1 <= len(name) <= 40 or any(ord(ch) < 32 for ch in name):
            return 400, {"error": "The name is 1 to 40 characters.", "field": "name"}
        if not isinstance(vals, dict) or set(vals) != set(COMBO_KEYS):
            return 400, {"error": "values holds exactly the 14 colors.", "field": "values"}
        for k in COMBO_KEYS:
            if not isinstance(vals[k], str) or not re.fullmatch(r"#[0-9a-f]{6}", vals[k]):
                return 400, {"error": f"{k} is a color written #rrggbb in lowercase.", "field": k}
        same = next((c for c in self.combos if c["name"].casefold() == name.casefold()), None)
        if same:
            same.update(name=name, values=dict(vals), saved=self.combo_clock, via="sala-web")
        elif len(self.combos) >= COMBOS_MAX:
            return 409, {"error": f"The list is full ({COMBOS_MAX}): delete one first.", "field": None}
        else:
            self.combos.append({"id": "c" + secrets.token_hex(4), "name": name, "values": dict(vals), "saved": self.combo_clock, "via": "sala-web"})
        self.combo_clock += 1
        return self._combos_out()

    # ── For you: stackshot's shapes ──────────────────────────────
    def _seen(self, b: dict) -> tuple[int, object]:
        if self.seen_reply:
            return self.seen_reply
        if b.get("sender") != "sala-web":
            return 403, {"error": f"refused: sender {b.get('sender')!r} may not mark entries seen from here"}
        rid = b.get("id")
        if rid == "all":
            ids = sorted(r["id"] for r in self.foryou)     # an empty list gives 200 with seen: []
        elif isinstance(rid, int) and not isinstance(rid, bool) and rid >= 1:
            if not any(r["id"] == rid for r in self.foryou):
                return 404, {"error": f"no entry {rid} on the list"}      # not on the list, one already marked seen included
            ids = [rid]
        else:
            return 400, {"error": 'id is an entry number or "all"'}
        self.seen_ids |= set(ids)
        self.foryou = [r for r in self.foryou if r["id"] not in ids]
        out: dict = {"ok": True, "seen": ids}
        if not self.seen_without_rows:
            out["rows"] = list(self.foryou)
        return 200, out

    def _watch(self, key: str, b: dict) -> tuple[int, object]:
        if self.watch_reply:
            return self.watch_reply
        if b.get("sender") != "sala-web":
            return 403, {"error": f"refused: sender {b.get('sender')!r} may not set flags from here"}
        key = key if "#" in key else f"board#{key}"
        if key not in self.known_items:
            return 404, {"error": f"no item {key}"}
        state = b.get("state")
        if state not in ("watch", "mute", "default"):
            return 400, {"error": "state = watch | mute | default"}
        if state == "default":
            self.flags.pop(key, None)
        else:
            self.flags[key] = state
        out: dict = {"ok": True, "item": key, "state": state}
        if not self.watch_without_flags:
            out["flags"] = dict(self.flags)
        return 200, out
