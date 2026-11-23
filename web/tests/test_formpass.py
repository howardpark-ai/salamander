"""The pass the New session form's calls carry (formpass.py, and `form=True` in projpick._request): the agent add, the For you list's two writes and the color combos writes go with
sala's pass when lib/stackshot_key.py has one, and with the machine token otherwise; every other call keeps the machine token.

A stand-in for the key script (SALA_STACKSHOT_KEY_PY) answers `form-pass` with a made-up pass, or with nothing, and records `forget-pass`; a stand-in server on 127.0.0.1 records the
Authorization header of each call and can refuse a pass. The real key script and its signing are in tests/stackshotkey.sh. Nothing here reaches stackshot or the network."""

from __future__ import annotations

import json
import stat
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

from sala_web import colors as CO
from sala_web import foryou as FY
from sala_web import projpick as PP

TOKEN = "machine-token-for-the-test"
PASS = "ssp_standin-pass-for-the-test"


class Server:
    def __init__(self, refuse_pass: int = 0):
        self.calls: list[tuple[str, str, str]] = []      # method, path, the bearer
        outer = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _answer(self):
                bearer = (self.headers.get("Authorization") or "").removeprefix("Bearer ")
                n = int(self.headers.get("Content-Length") or 0)
                if n:
                    self.rfile.read(n)
                outer.calls.append((self.command, self.path.split("?")[0], bearer))
                status = outer.refuse_pass if (bearer == PASS and outer.refuse_pass) else 200
                raw = json.dumps({"error": "refused"} if status != 200 else {"ok": True}).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            do_GET = do_POST = _answer

        self.refuse_pass = refuse_pass
        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.url = "http://127.0.0.1:%d" % self.srv.server_address[1]
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def close(self):
        self.srv.shutdown()
        self.srv.server_close()


@pytest.fixture()
def world(tmp_path, monkeypatch):
    """token and address files, a stand-in key script, and a server; returns (server, token path, url path, forget-log path)."""
    srv = Server()
    tok, url = tmp_path / "client.token", tmp_path / "client.url"
    tok.write_text(TOKEN + "\n")
    url.write_text(srv.url + "\n")
    log = tmp_path / "standin.log"
    script = tmp_path / "standin_key.py"
    script.write_text(
        "import os, sys\n"
        "if sys.argv[1] == 'form-pass':\n"
        "    open(os.environ['STANDIN_LOG'], 'a').write('form-pass url=' + os.environ.get('STACKSHOT_URL', '') + '\\n')\n"
        "    if os.environ.get('STANDIN_MODE') == 'none': sys.exit(1)\n"
        "    print('" + PASS + "')\n"
        "elif sys.argv[1] == 'forget-pass':\n"
        "    open(os.environ['STANDIN_LOG'], 'a').write('forget-pass\\n')\n")
    script.chmod(stat.S_IRUSR | stat.S_IWUSR)
    monkeypatch.setenv("SALA_STACKSHOT_PASS", "on")
    monkeypatch.setenv("SALA_STACKSHOT_KEY_PY", str(script))
    monkeypatch.setenv("STANDIN_LOG", str(log))
    monkeypatch.delenv("STANDIN_MODE", raising=False)
    yield srv, tok, url, log
    srv.close()


def standin_log(log: Path) -> list[str]:
    return log.read_text().splitlines() if log.exists() else []


def test_the_agent_add_goes_with_the_pass_and_everything_else_with_the_token(world):
    srv, tok, url, log = world
    api = PP.Stackshot(tok, url)
    assert api.add_agent({"project": "projects/x", "name": "x-a", "role": "a", "front": False, "mandate": "m", "sender": "sala-web"}).status == 200
    assert api.projects("all", "").status == 200
    assert api.new_project({"key": "projects/y", "scope": "gamma", "sender": "sala-web"}).status == 200
    assert api.list_project({"key": "projects/y", "sender": "sala-web"}).status == 200
    assert api.item_facts("item#1").status == 200
    assert [(m, p, b) for m, p, b in srv.calls] == [
        ("POST", "/client/project-agent", PASS), ("GET", "/client/projects", TOKEN), ("POST", "/client/project", TOKEN),
        ("POST", "/client/project-list", TOKEN), ("GET", "/client/item-facts", TOKEN)]
    assert standin_log(log) == ["form-pass url=" + srv.url]       # the claim's audience is the address the call goes to


def test_the_for_you_writes_and_the_color_writes_go_with_the_pass_and_their_reads_with_the_token(world):
    srv, tok, url, log = world
    fy, co = FY.Calls(tok, url), CO.Calls(tok, url)
    fy.list(); fy.seen({"id": 3, "sender": "sala-web"}); fy.watch("item#9", {"state": "watch", "sender": "sala-web"})
    co.list(); co.save({"name": "n", "values": {}, "sender": "sala-web"}); co.delete({"id": "c1", "sender": "sala-web"})
    assert [(m, p, b) for m, p, b in srv.calls] == [
        ("GET", "/client/for-you", TOKEN), ("POST", "/client/for-you/seen", PASS), ("POST", "/client/items/item%239/watch", PASS),
        ("GET", "/client/colors/combos", TOKEN), ("POST", "/client/colors/combos", PASS), ("POST", "/client/colors/combos/delete", PASS)]


@pytest.mark.parametrize("how", ["off", "none", "no-script"])
def test_with_no_pass_the_form_call_uses_the_machine_token_as_before(world, monkeypatch, how):
    srv, tok, url, log = world
    if how == "off":
        monkeypatch.setenv("SALA_STACKSHOT_PASS", "off")
    elif how == "none":
        monkeypatch.setenv("STANDIN_MODE", "none")        # the script has no pass to give (no key, a key still waiting, a server that says no)
    else:
        monkeypatch.setenv("SALA_STACKSHOT_KEY_PY", str(tok.parent / "missing.py"))
    rep = PP.Stackshot(tok, url).add_agent({"project": "projects/x", "name": "x-a", "role": "a", "front": False, "mandate": "m", "sender": "sala-web"})
    assert rep.status == 200
    assert [(m, p, b) for m, p, b in srv.calls] == [("POST", "/client/project-agent", TOKEN)]
    if how == "off":
        assert standin_log(log) == []                      # switched off: the script is not even asked


@pytest.mark.parametrize("status", [401, 403])
def test_a_pass_the_server_refuses_is_dropped_and_the_call_made_again_with_the_token(world, status):
    srv, tok, url, log = world
    srv.refuse_pass = status          # for example a restart of the server, which ends every pass
    rep = PP.Stackshot(tok, url).add_agent({"project": "projects/x", "name": "x-a", "role": "a", "front": False, "mandate": "m", "sender": "sala-web"})
    assert rep.status == 200 and rep.data == {"ok": True}
    assert [(m, p, b) for m, p, b in srv.calls] == [("POST", "/client/project-agent", PASS), ("POST", "/client/project-agent", TOKEN)]
    assert standin_log(log) == ["form-pass url=" + srv.url, "forget-pass"]


def test_neither_the_pass_nor_the_token_is_in_what_a_failed_call_returns(world):
    srv, tok, url, log = world
    srv2 = Server(refuse_pass=0)
    srv2.close()                                           # nothing listens any more: the call cannot be made
    url.write_text(srv2.url + "\n")
    rep = PP.Stackshot(tok, url).add_agent({"project": "projects/x", "name": "x-a", "role": "a", "front": False, "mandate": "m", "sender": "sala-web"})
    text = json.dumps(rep.data) + str(rep.status)
    assert rep.status == 0 and PASS not in text and TOKEN not in text and srv2.url not in text
