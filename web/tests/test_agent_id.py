"""The permanent agent id the sidebar keys the owner's saved order on (sala's registry, sessions.json; docs/session-registry.md).

A session's name changes (`sala rename`, a title the conversation carries) and so do its pid, pane and conversation id (a recycle
resumes, a /clear starts a new one). The registry row's id is minted once and outlives all of them. What a wrong answer costs: the
order the owner dragged is lost with the name, or two sessions share one place."""

from __future__ import annotations

import json

from sala_web import sessions as S


def sess(name, sid=None, tmux=""):
    return S.Session(pid=1, session_id=sid or name, name=name, cwd="/tmp", status="idle", tmux=tmux)


def row(rid, name, transcripts=(), aliases=(), pane=None, state="live"):
    return {"id": rid, "name": name, "pane": pane or name, "state": state, "aliases": list(aliases),
            "transcripts": [{"id": t, "why": "add"} for t in transcripts]}


def test_the_id_follows_the_agent_through_a_rename_and_a_new_conversation():
    rows = [row("id-a", "demo-b", ["conv-1", "conv-2"], aliases=["demo-a"]), row("id-c", "demo-c", ["conv-3"])]
    renamed = sess("demo-a", "conv-1")          # the old name still on the process, the conversation finds the row
    cleared = sess("demo-c", "conv-new")        # a conversation the registry has not recorded yet: the name finds the row
    S.attach_agent_ids([renamed, cleared], rows)
    assert (renamed.agent_id, cleared.agent_id) == ("id-a", "id-c")
    assert renamed.to_json()["agentId"] == "id-a" and renamed.to_json()["aliases"] == ["demo-a"]
    assert "aliases" not in cleared.to_json()


def test_the_tmux_session_finds_the_row_when_name_and_conversation_do_not():
    rows = [row("id-a", "demo-a", ["conv-1"], pane="demo-pane")]
    s = sess("title-the-conversation-carries", "conv-x", tmux="demo-pane:@1.%1")
    S.attach_agent_ids([s], rows)
    assert s.agent_id == "id-a"


def test_a_row_belongs_to_one_session_and_a_session_with_no_row_has_no_id():
    rows = [row("id-a", "demo-a", ["conv-1"])]
    owner, twin, nobody = sess("demo-a", "conv-1"), sess("demo-a", "conv-y"), sess("demo-none")
    S.attach_agent_ids([twin, owner, nobody], rows)
    assert (owner.agent_id, twin.agent_id, nobody.agent_id) == ("id-a", None, None)
    assert "agentId" not in nobody.to_json() and "aliases" not in nobody.to_json()   # the page keys it on its name


def test_the_conversation_beats_the_name_whatever_the_order():
    rows = [row("id-a", "demo-a", ["conv-a"]), row("id-b", "demo-b", ["conv-b"])]
    first, second = sess("demo-a", "conv-b"), sess("demo-b", "conv-a")      # a rename half done: names crossed
    S.attach_agent_ids([first, second], rows)
    assert (first.agent_id, second.agent_id) == ("id-b", "id-a")


def test_load_agent_rows_reads_live_rows_only_and_survives_a_bad_file(tmp_path):
    f = tmp_path / "sessions.json"
    assert S.load_agent_rows(f) == []                                       # missing
    f.write_text("{not json")
    assert S.load_agent_rows(f) == []                                       # unreadable
    f.write_text(json.dumps({"sessions": {"x": row("id-x", "demo-x"), "y": row("id-y", "demo-y", state="retired"), "z": "junk"}}))
    assert [r["id"] for r in S.load_agent_rows(f)] == ["id-x"]              # a retired row is no one's
    f.write_text(json.dumps({"sessions": ["not", "a", "dict"]}))
    assert S.load_agent_rows(f) == []
