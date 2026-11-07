"""The color tool's saved combinations, server side (colors.py and the three routes /api/colors/combos, /api/colors/combos/delete): sala's
server proxies stackshot's one list on the account with this machine's token and the sender label `sala-web`, which the server sets and the
browser never sees.

What a wrong answer costs: a body that is not the name and the 14 colors reaching stackshot, a browser-supplied sender or an extra field
forwarded, a token or an address in anything the page can read, a stackshot failure that breaks the page instead of arriving as
{"error", "field"} with a status the panel can use, a cached list (a combination saved from the other app would not show), or a replace
that adds a second row.

Everything runs against the fake stackshot (fake_stackshot.py, a real HTTP server on 127.0.0.1 that answers the three routes the way stackshot
answers them); the real one is never called. The panel's side is in test_colortool_wiring.py. Not covered: the real stackshot's contrast-free storage
and its 4 KB limit (the fake can only be told to answer 413)."""

from __future__ import annotations

import json

import pytest
from starlette.testclient import TestClient

from fake_stackshot import FakeStackshot
from sala_web import colors as C
from sala_web.app import create_app
from sala_web.config import Settings

VALUES = {"bg": "#161617", "card": "#1f1f21", "fg": "#ececea", "mut": "#a3a29d", "line": "#2c2c2e", "ibd": "#929190", "link": "#f0a06a",
          "solid": "#bd561d", "onsolid": "#ffffff", "labbg": "#3a2619", "labfg": "#f0a06a", "labbd": "#3a2619", "disbg": "#2a2a2c", "disfg": "#a3a29d"}
URL = "/api/colors/combos"


@pytest.fixture
def fake(tmp_path):
    f = FakeStackshot(tmp_path / "stackshot-cfg")
    yield f
    f.close()


def make_client(tmp_path, token_file, url_file) -> TestClient:
    claude = tmp_path / "claude"
    (claude / "sessions").mkdir(parents=True, exist_ok=True)
    (claude / "projects").mkdir(exist_ok=True)
    settings = Settings(socket=tmp_path / "s.sock", state_dir=tmp_path / "state", claude_dir=claude, tmux_socket_name="salaweb-pytest-unused",
                        roles_cmd=["false"], stackshot_token=token_file, stackshot_url=url_file)
    return TestClient(create_app(settings))


@pytest.fixture
def client(tmp_path, fake):
    return make_client(tmp_path, fake.token_file, fake.url_file)


def save(client, name="Mine", values=VALUES, **extra):
    return client.post(URL, json={"name": name, "values": values, **extra})


def posts(fake) -> list[dict]:
    return [r for r in fake.requests if r["method"] == "POST" and "colors" in r["path"]]


def check_plain(r, fake):
    """Every answer: no store, JSON, and nothing of the token or the address in it."""
    assert r.headers["cache-control"] == "no-store"
    assert fake.token not in r.text and fake.url not in r.text and "Bearer" not in r.text


# --- the list ----------------------------------------------------------------------------------------------------------------

def test_the_list_is_stackshots_and_is_not_cached(client, fake):
    r = client.get(URL)
    assert r.status_code == 200 and r.json() == {"combos": [], "max": 50}
    check_plain(r, fake)
    assert save(client).status_code == 200
    # a combination another page saves shows at the next read: nothing is kept here
    fake.combos.append({"id": "x1", "name": "From the other app", "values": dict(VALUES), "saved": 1792800001, "via": "browser"})
    got = client.get(URL).json()["combos"]
    assert [c["name"] for c in got] == ["Mine", "From the other app"]
    assert got[0].keys() == {"id", "name", "values", "saved", "via"} and got[0]["values"] == VALUES and got[0]["via"] == "sala-web"
    fake.combos.clear()
    assert client.get(URL).json()["combos"] == []


def test_a_row_stackshot_sends_that_is_not_a_row_is_left_out(client, fake):
    good = {"id": "g", "name": "Good", "values": dict(VALUES), "saved": 5, "via": "sala-web"}
    fake.combos = [good, {"id": "b1", "name": "", "values": dict(VALUES)}, {"id": "b2", "name": "No values", "values": {"bg": "#161617"}},
                   {"id": "b3", "name": "Bad color", "values": {**VALUES, "bg": "red"}}, "junk", {"name": "No id", "values": dict(VALUES)}]
    got = client.get(URL).json()
    assert [c["id"] for c in got["combos"]] == ["g"]
    fake.combos_reply = (200, {"nope": []})
    r = client.get(URL)
    assert r.status_code == 502 and r.json()["error"] and r.json()["field"] is None


# --- save --------------------------------------------------------------------------------------------------------------------

def test_a_save_forwards_the_name_and_the_14_colors_with_the_sender_set_here(client, fake):
    r = save(client, "  Evening look ")
    assert r.status_code == 200
    check_plain(r, fake)
    body = r.json()
    assert body["max"] == 50 and [c["name"] for c in body["combos"]] == ["Evening look"] and body["combos"][0]["values"] == VALUES
    assert posts(fake) == [{"method": "POST", "path": "/client/colors/combos", "body": {"name": "Evening look", "values": VALUES, "sender": "sala-web"}}]


def test_the_browser_cannot_set_the_sender_or_add_a_field(client, fake):
    for extra in ({"sender": "sala-rename"}, {"sender": "sala-web"}, {"id": "c1"}, {"token": "x"}):
        r = save(client, **extra)
        assert r.status_code == 400 and r.json()["field"] is None and "Unknown fields" in r.json()["error"], extra
    assert posts(fake) == []                                      # none of them reached stackshot
    r = client.post(URL + "/delete", json={"id": "c1", "sender": "sala-rename"})
    assert r.status_code == 400 and posts(fake) == []


def test_a_name_is_nfc_and_trimmed_and_the_same_name_in_another_case_replaces_it_in_place(client, fake):
    assert save(client, "Café").json()["combos"][0]["name"] == "Café"            # e + combining acute -> é
    assert save(client, "Second").status_code == 200
    r = save(client, "  CAFÉ  ", {**VALUES, "link": "#ffa057"})
    names = [c["name"] for c in r.json()["combos"]]
    assert names == ["CAFÉ", "Second"] and r.json()["combos"][0]["values"]["link"] == "#ffa057" and len(fake.combos) == 2


def test_the_colors_are_lowercased_and_the_name_may_be_forty_characters(client, fake):
    r = save(client, "n" * 40, {k: v.upper() for k, v in VALUES.items()})
    assert r.status_code == 200 and r.json()["combos"][0]["values"] == VALUES


@pytest.mark.parametrize("name,why", [("", "empty"), ("   ", "blank"), ("n" * 41, "41 characters"), ("a\nb", "newline"), ("a\x00b", "NUL"),
                                      ("a​b", "zero-width space (a format character)"), ("a‮b", "a direction override"), (5, "a number"),
                                      (None, "null"), (["x"], "a list")])
def test_a_bad_name_is_a_400_on_name_and_never_reaches_stackshot(client, fake, name, why):
    r = save(client, name)
    assert r.status_code == 400, why
    assert r.json()["field"] == "name" and r.json()["error"], why
    check_plain(r, fake)
    assert posts(fake) == []


def test_a_name_without_the_key_is_a_400(client, fake):
    r = client.post(URL, json={"values": VALUES})
    assert r.status_code == 400 and r.json()["field"] == "name"
    assert posts(fake) == []


@pytest.mark.parametrize("make,field", [
    (lambda v: {k: x for k, x in v.items() if k != "disfg"}, "values"),                      # a key short
    (lambda v: {**v, "extra": "#000000"}, "values"),                                          # a key over
    (lambda v: {**v, "bg": "red"}, "bg"), (lambda v: {**v, "link": "#fff"}, "link"), (lambda v: {**v, "solid": "#12345g"}, "solid"),
    (lambda v: {**v, "labbd": "#1234567"}, "labbd"), (lambda v: {**v, "mut": 3}, "mut"), (lambda v: {**v, "ibd": None}, "ibd"),
    (lambda v: {**v, "disbg": "rgb(1,2,3)"}, "disbg"), (lambda v: list(v.values()), "values"), (lambda v: "#161617", "values"), (lambda v: None, "values"),
])
def test_values_must_be_exactly_the_14_keys_each_a_hex_color(client, fake, make, field):
    r = save(client, values=make(VALUES))
    assert r.status_code == 400 and r.json()["field"] == field, r.text
    assert posts(fake) == []


def test_the_body_must_be_a_json_object_from_this_page_and_not_huge(client, fake):
    assert client.post(URL, json=[1, 2]).status_code == 400
    r = client.post(URL, content=b"{not json", headers={"content-type": "application/json"})
    assert r.status_code == 400 and r.json() == {"error": "body must be JSON", "field": None}
    r = client.post(URL, content=b'{"name":"x"}', headers={"content-type": "text/plain"})
    assert r.status_code == 415 and r.json()["field"] is None
    r = client.post(URL, json={"name": "x", "values": VALUES}, headers={"origin": "https://elsewhere.example"})
    assert r.status_code == 403 and r.json()["field"] is None
    r = client.post(URL, content=json.dumps({"name": "x" * 20000}).encode(), headers={"content-type": "application/json"})
    assert r.status_code == 413 and r.json()["field"] is None
    assert posts(fake) == []


# --- delete ------------------------------------------------------------------------------------------------------------------

def test_delete_sends_the_id_with_the_sender_and_an_unknown_id_is_not_an_error(client, fake):
    first = save(client, "One").json()["combos"][0]["id"]
    save(client, "Two")
    r = client.post(URL + "/delete", json={"id": first})
    assert r.status_code == 200 and [c["name"] for c in r.json()["combos"]] == ["Two"]
    check_plain(r, fake)
    assert posts(fake)[-1]["body"] == {"id": first, "sender": "sala-web"} and posts(fake)[-1]["path"] == "/client/colors/combos/delete"
    r = client.post(URL + "/delete", json={"id": "nothing-like-it"})
    assert r.status_code == 200 and [c["name"] for c in r.json()["combos"]] == ["Two"]


@pytest.mark.parametrize("body", [{}, {"id": ""}, {"id": 4}, {"id": None}, {"id": "a" * 81}, {"id": "a\nb"}, {"id": "x", "name": "y"}, []])
def test_a_bad_delete_is_a_400_and_never_reaches_stackshot(client, fake, body):
    r = client.post(URL + "/delete", json=body)
    assert r.status_code == 400 and "error" in r.json() and "field" in r.json(), body
    assert posts(fake) == []


# --- stackshot's refusals pass through as {error, field} ---------------------------------------------------------------------------

@pytest.mark.parametrize("status,field", [(400, "link"), (400, "values"), (403, "sender"), (403, None), (409, None), (413, None), (415, None)])
def test_stackshots_own_sentence_and_field_pass_through(client, fake, status, field):
    fake.combos_reply = (status, {"error": f"Plain sentence for {status}.", "field": field})
    for r in (client.get(URL), save(client), client.post(URL + "/delete", json={"id": "c1"})):
        assert r.status_code == status and r.json() == {"error": f"Plain sentence for {status}.", "field": field}
        check_plain(r, fake)


def test_a_list_that_is_full_is_a_409_with_the_sentence(client, fake):
    for i in range(50):
        assert save(client, f"combo {i}").status_code == 200
    r = save(client, "one too many")
    assert r.status_code == 409 and "full" in r.json()["error"]
    assert save(client, "COMBO 3").status_code == 200                      # a replace is not an addition


def test_a_field_stackshot_names_that_is_not_one_of_ours_becomes_null_and_a_long_sentence_is_cut(client, fake):
    fake.combos_reply = (400, {"error": "x" * 500, "field": "../../etc/passwd"})
    r = client.get(URL)
    assert r.status_code == 400 and r.json()["field"] is None and len(r.json()["error"]) == C.SENTENCE_MAX


@pytest.mark.parametrize("reply,status", [((503, {"error": "The saved list is on a standby copy.", "field": None}), 503),
                                           ((500, {"error": "boom", "field": None}), 502), ((502, "bad gateway"), 502), ((404, "no such read"), 502)])
def test_other_failures_are_told_in_the_servers_words_with_a_status_the_panel_can_use(client, fake, reply, status):
    fake.combos_reply = reply
    r = client.get(URL)
    assert r.status_code == status and r.json()["field"] is None and r.json()["error"]
    check_plain(r, fake)


def test_stackshot_sending_something_that_is_not_the_list_is_a_502(client, fake):
    for bad in ({"combos": "x"}, ["list"], "html page"):
        fake.combos_reply = (200, bad)
        r = client.get(URL)
        assert r.status_code == 502 and r.json() == {"error": "stackshot sent an answer that is not the saved list.", "field": None}


# --- stackshot away or not set up ------------------------------------------------------------------------------------------------------

def test_stackshot_unreachable_is_a_502_and_says_so_without_the_address(tmp_path, fake):
    c = make_client(tmp_path, fake.token_file, fake.url_file)
    fake.close()
    for r in (c.get(URL), save(c), c.post(URL + "/delete", json={"id": "c1"})):
        assert r.status_code == 502 and "unreachable" in r.json()["error"] and r.json()["field"] is None
        assert fake.token not in r.text and "127.0.0.1" not in r.text


def test_a_machine_with_no_token_or_address_gets_a_503_and_the_rest_of_sala_still_works(tmp_path):
    c = make_client(tmp_path, tmp_path / "no-token", tmp_path / "no-url")
    r = c.get(URL)
    assert r.status_code == 503 and r.json() == {"error": "No stackshot token on this machine.", "field": None}
    assert r.headers["cache-control"] == "no-store"
    assert save(c).status_code == 503
    assert c.get("/api/prefs").status_code == 200                      # the page's other routes are untouched
    (tmp_path / "tok").write_text("secret-token-value\n")
    r = make_client(tmp_path, tmp_path / "tok", tmp_path / "no-url").get(URL)
    assert r.status_code == 503 and "address" in r.json()["error"] and "secret-token-value" not in r.text


def test_a_refused_token_is_a_502_that_names_neither_the_token_nor_the_address(tmp_path, fake):
    (tmp_path / "wrong.token").write_text("not-the-token\n")
    c = make_client(tmp_path, tmp_path / "wrong.token", fake.url_file)
    for r in (c.get(URL), save(c)):
        assert r.status_code == 502 and r.json() == {"error": C.REFUSED, "field": None}
        assert "not-the-token" not in r.text and fake.url not in r.text


# --- the validators on their own ------------------------------------------------------------------------------------------------------

def test_the_key_list_is_the_14_stackshot_names_in_order():
    assert C.KEYS == tuple(VALUES) and len(C.KEYS) == 14
    assert C.SENDER == "sala-web"
