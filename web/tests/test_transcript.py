import json

from sala_web import transcript as TR

SID = "11111111-2222-3333-4444-555555555555"


def line(**kw):
    d = {"uuid": kw.pop("uuid", "u1"), "timestamp": "2026-10-13T00:00:00Z", "sessionId": SID}
    d.update(kw)
    return d


def test_project_slug_matches_cli_rule():
    assert TR.project_slug("/home/alex/.cache/lane-test") == "-home-alex--cache-lane-test"
    assert TR.project_slug("/home/alex/demo-hub/demo-ops") == "-home-alex-demo-hub-demo-ops"


def test_user_text_strips_system_reminders():
    m = TR.parse_line(line(type="user", message={"role": "user", "content":
        "hello<system-reminder>secret context</system-reminder>"}), SID)
    assert m["blocks"] == [{"kind": "text", "text": "hello", "truncated": False}]


def test_reminder_only_and_meta_lines_are_skipped():
    assert TR.parse_line(line(type="user", message={"content": "<system-reminder>x</system-reminder>"}), SID) is None
    assert TR.parse_line(line(type="user", isMeta=True, message={"content": "Stop hook feedback: x"}), SID) is None
    assert TR.parse_line(line(type="system", content="x"), SID) is None
    assert TR.parse_line(line(type="assistant", isSidechain=True,
                              message={"content": [{"type": "text", "text": "x"}]}), SID) is None


def test_peer_message_is_a_notice():
    m = TR.parse_line(line(type="user", isMeta=True, message={"content":
        "Another Claude session sent a message:\nfrom: demo\n[stackshot message] hi"}), SID)
    assert m["blocks"][0]["kind"] == "notice"
    assert m["blocks"][0]["label"] == "message from demo"


def _peer_label(body):
    m = TR.parse_line(line(type="user", isMeta=True, message={"content":
        "Another Claude session sent a message:\n" + body}), SID)
    b = m["blocks"][0]
    assert b["kind"] == "notice"
    return b["label"]


def test_peer_label_cross_session_wrapper_reads_from_name_not_the_body():
    # the body's "from here" once made the pill read "message from here"
    tag = ('<cross-session-message from="uds:/run/user/1000/cc-socks/7.sock" '
           'from-name="demo-ci" from-mode="prompting">')
    body = tag + "\ninfra-demo-ci has taken over the CI threads from here, thanks\n</cross-session-message>"
    assert _peer_label(body) == "message from demo-ci"


def test_peer_label_cross_session_wrapper_falls_back_to_from_attribute():
    assert _peer_label('<cross-session-message from="example-x" from-mode="prompting">\nhello from here\n'
                       '</cross-session-message>') == "message from example-x"
    # a socket address alone names nobody
    assert _peer_label('<cross-session-message from="uds:/run/user/1000/cc-socks/1.sock">\nsent from here\n'
                       '</cross-session-message>') == "message from another session"


def test_peer_label_never_takes_a_word_from_the_body():
    assert _peer_label("taken over from here, and from there too") == "message from another session"
    assert _peer_label("<agent-message from=\"a1b2c3d4e5f607182\">\n[Subagent hand-back] NOT a message from the user"
                       "\n</agent-message>") == "message from another session"
    # a wrapper's body cannot name the sender either, nor can a later line of a header-form message
    assert _peer_label('<cross-session-message from-mode="prompting">\nfrom: someone-else\n'
                       '</cross-session-message>') == "message from another session"
    assert _peer_label("from: demo\n[stackshot message] hi\n\nlater\nfrom: someone-else") == "message from demo"
    assert _peer_label("hello\n\n\nfrom: someone-else\nfrom there") == "message from another session"


def test_peer_label_header_forms():
    assert _peer_label("from: demo\n[stackshot message] hi") == "message from demo"
    assert _peer_label("from: stackshot (router)\n[stackshot] router: notice passed") == "message from stackshot"
    assert _peer_label("from: alex-builder\n[stackshot message] from alex-builder · 2030-01-05 09:30 +04\nbody"
                       ) == "message from alex-builder"
    # the stackshot note's own header line, with no `from:` line above it
    assert _peer_label("[stackshot message] from demo-helper · 2030-01-05 09:30 +04\nboard#40 ... from here"
                       ) == "message from demo-helper"


def test_slash_command_and_output():
    m = TR.parse_line(line(type="user", message={"content":
        "<command-name>/model</command-name>\n<command-message>model</command-message>\n<command-args>opus</command-args>"}), SID)
    assert m["blocks"] == [{"kind": "command", "text": "/model opus"}]
    m = TR.parse_line(line(type="user", message={"content": "<local-command-stdout>Bye!</local-command-stdout>"}), SID)
    assert m["blocks"][0]["kind"] == "notice" and m["blocks"][0]["text"] == "Bye!"


def test_assistant_blocks():
    m = TR.parse_line(line(type="assistant", message={"content": [
        {"type": "thinking", "thinking": ""},  # redacted thinking: nothing to show
        {"type": "text", "text": "**hi**"},
        {"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "ls -la", "description": "List files"}},
    ]}), SID)
    kinds = [b["kind"] for b in m["blocks"]]
    assert kinds == ["text", "tool_use"]
    assert m["blocks"][1]["summary"] == "List files"


def test_tool_result_with_image():
    m = TR.parse_line(line(type="user", uuid="u9", message={"content": [
        {"type": "tool_result", "tool_use_id": "t1", "content": [
            {"type": "text", "text": "ok"}, {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "AA=="}}]}]}), SID)
    b = m["blocks"][0]
    assert b["kind"] == "tool_result" and b["toolUseId"] == "t1" and b["text"] == "ok"
    assert b["images"] == [f"api/image/{SID}/u9/0/1"]


def test_queued_prompt_attachment_is_a_user_message():
    m = TR.parse_line(line(type="attachment", attachment={"type": "queued_command", "commandMode": "prompt",
                                                          "prompt": "typed while busy"}), SID)
    assert m["role"] == "user" and m["blocks"][0]["text"] == "typed while busy"
    assert TR.parse_line(line(type="attachment", attachment={"type": "hook_success"}), SID) is None


def test_read_tail_and_read_from(tmp_path):
    p = tmp_path / f"{SID}.jsonl"
    rows = [line(type="user", uuid=f"u{i}", message={"content": f"msg {i}"}) for i in range(10)]
    p.write_text("".join(json.dumps(r) + "\n" for r in rows) + '{"partial":')
    msgs, off = TR.read_tail(p, SID, n=3)
    assert [m["uuid"] for m in msgs] == ["u7", "u8", "u9"]
    with p.open("a") as f:
        f.write(' 1}\n' + json.dumps(line(type="user", uuid="u10", message={"content": "new"})) + "\n")
    more, off2 = TR.read_from(p, SID, off)
    assert [m["uuid"] for m in more] == ["u10"] and off2 == p.stat().st_size


def test_find_image(tmp_path):
    p = tmp_path / f"{SID}.jsonl"
    p.write_text(json.dumps(line(type="user", uuid="img1", message={"content": [
        {"type": "text", "text": "see"},
        {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "aGk="}}]})) + "\n")
    assert TR.find_image(p, "img1", 1, -1) == ("image/png", b"hi")
    assert TR.find_image(p, "nope", 1, -1) is None


def test_pasted_content_wrapper_is_stripped():
    text = '\n\n<pasted_content id="a1">\nPS C:\\Users\\alex> ssh box-a\nok\n</pasted_content id="a1">\n'
    m = TR.parse_line(line(type="user", message={"role": "user", "content": text}), SID)
    assert m["blocks"] == [{"kind": "text", "text": "PS C:\\Users\\alex> ssh box-a\nok", "truncated": False}]
    # mixed with typed text, with and without an id, and in a queued prompt
    m = TR.parse_line(line(type="user", message={"content": [{"type": "text", "text":
        'look at this <pasted_content>a\nb</pasted_content> thanks'}]}), SID)
    assert m["blocks"][0] == {"kind": "text", "text": "look at this a\nb thanks", "truncated": False}
    m = TR.parse_line(line(type="attachment", attachment={"type": "queued_command", "prompt":
        '<pasted_content id="abcd">queued words</pasted_content id="abcd">'}), SID)
    assert m["blocks"][0] == {"kind": "text", "text": "queued words", "truncated": False}


def test_assistant_reply_carries_model_and_effort():
    d = {"type": "assistant", "uuid": "u1", "effort": "medium", "perTurnEffort": "high",
         "message": {"model": "claude-opus-5-5", "content": [{"type": "text", "text": "hi"}]}}
    m = TR.parse_line(d, "s")
    assert m["model"] == "claude-opus-5-5" and m["effort"] == "high"
    d["message"]["model"] = "<synthetic>"
    assert "model" not in TR.parse_line(d, "s")


# ---------- the output of a `!` command: its own block kind, shown open; everything else stays a notice ----------

def _user(content):
    return TR.parse_line(line(type="user", message={"role": "user", "content": content}), SID)["blocks"]


def test_bang_stdout_is_a_bang_output_block():
    # the shape of a real record: both tags in one record, stderr empty
    assert _user("<bash-stdout>one\ntwo\nthree</bash-stdout><bash-stderr></bash-stderr>") == [
        {"kind": "bang_output", "label": "command output", "text": "one\ntwo\nthree", "truncated": False}]


def test_bang_stderr_alone_and_both_streams():
    (b,) = _user("<bash-stdout></bash-stdout><bash-stderr>boom</bash-stderr>")
    assert (b["kind"], b["text"]) == ("bang_output", "boom"), b
    (b,) = _user("<bash-stderr>boom</bash-stderr>")
    assert (b["kind"], b["text"]) == ("bang_output", "boom"), b
    # stdout then stderr, neither tag left in the text (the stderr used to be dropped when stdout had text)
    (b,) = _user("<bash-stdout>out</bash-stdout><bash-stderr>err a\nerr b</bash-stderr>")
    assert b["text"] == "out\nerr a\nerr b", b


def test_bang_stdout_holding_the_closing_tag_is_not_cut_short():
    # grep -r bash-stdout prints the tag as text: the match is greedy, anchored on the stderr part
    (b,) = _user("<bash-stdout>a.py:  rec = '</bash-stdout>'\nb.py: tail</bash-stdout><bash-stderr>warn</bash-stderr>")
    assert b["text"] == "a.py:  rec = '</bash-stdout>'\nb.py: tail\nwarn", b
    # the stderr is read once: no copy of it in the text
    assert b["text"].count("warn") == 1, b
    # stdout alone, the tag as text inside it
    (b,) = _user("<bash-stdout>x </bash-stdout> y</bash-stdout>")
    assert b["text"] == "x </bash-stdout> y", b
    # stderr holding its own closing tag as text
    (b,) = _user("<bash-stdout></bash-stdout><bash-stderr>grep: '</bash-stderr>' no match</bash-stderr>")
    assert b["text"] == "grep: '</bash-stderr>' no match", b


def test_bang_unmatched_tag_falls_back_to_the_text_without_tags():
    # an opening tag with no close (a record cut short): the text shows, not "(no output)"
    (b,) = _user("<bash-stdout>partial output\nsecond line")
    assert (b["kind"], b["text"]) == ("bang_output", "partial output\nsecond line"), b
    (b,) = _user("<bash-stderr>boom")
    assert b["text"] == "boom", b
    # both inner values empty and nothing else: still an empty block
    (b,) = _user("<bash-stdout></bash-stdout><bash-stderr></bash-stderr>")
    assert b["text"] == "", b


def test_bang_with_no_output_is_an_empty_block():
    (b,) = _user("<bash-stdout></bash-stdout><bash-stderr></bash-stderr>")
    assert (b["kind"], b["text"], b["truncated"]) == ("bang_output", "", False), b
    assert "lines" not in b, b  # the page counts the lines itself


def test_bang_output_is_clipped_at_text_limit_and_says_so():
    (b,) = _user("<bash-stdout>" + "x" * (TR.TEXT_LIMIT + 50) + "</bash-stdout><bash-stderr></bash-stderr>")
    assert b["kind"] == "bang_output" and b["truncated"] is True and len(b["text"]) == TR.TEXT_LIMIT, b["truncated"]


def test_other_machine_output_stays_a_folded_notice():
    # a slash command's output, a task notification and another wrapper are notices, not bang output
    (b,) = _user("<local-command-stdout>ok</local-command-stdout>")
    assert (b["kind"], b["label"], b["text"]) == ("notice", "command output", "ok"), b
    (b,) = _user("<local-command-stderr>bad</local-command-stderr>")
    assert (b["kind"], b["label"]) == ("notice", "command output"), b
    (b,) = _user("<task-notification><summary>done</summary></task-notification>")
    assert (b["kind"], b["label"]) == ("notice", "done"), b
    (b,) = _user("<something-else>x</something-else>")
    assert (b["kind"], b["label"]) == ("notice", "something-else"), b
    # the command line itself is still a command block
    assert _user("<bash-input>ls</bash-input>") == [{"kind": "command", "text": "! ls"}]
