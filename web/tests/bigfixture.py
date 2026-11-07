"""A big, realistic transcript and a fleet of sessions, for the load measurement (tools/measure_load.py) and the tests of
the history render (test_timing_debug.py).

`big_transcript(n, scale)` writes n display messages the way a day's Claude Code transcript reads: the owner's prompts
with links, replies in markdown (headings, lists, a table, fenced code, links, bold) with their thinking, tool calls
(Bash, Read, Edit) with their inputs and results, notices from other sessions. Every message is a line the parser
(transcript.py) shows, so n lines are the n messages the stream's reset carries (TAIL_N = 200). Deterministic: the
text comes from a seeded generator, and `scale` stretches the filler so the reset payload can be sized to a byte
target (`fit_scale`). `fleet(n)` is n sessions' names, roles and projects across the three scopes, as stackshot's
`get roles` answers and the sidebar groups them.
"""

from __future__ import annotations

import json
import random

from conftest import transcript_line

WORDS = ("the deploy", "sala-web", "the socket", "the tunnel", "the runner", "stackshot", "gbrain", "the recycle", "sala",
         "the transcript", "a worktree", "the manifest", "the composer", "a pending bubble", "the sidebar", "the stream",
         "a fast-forward", "the unit", "the lockfile", "a 301", "the proxy", "the browser", "the keyboard", "the banner")
VERBS = ("reads", "keeps", "serves", "restarts", "fetches", "renders", "drops", "answers", "writes", "checks", "folds", "pins")
PATHS = ("web/src/sala_web/app.py", "web/src/sala_web/static/app.js", "lib/common.sh", "bin/salamander", "web/README.md",
         "tests/lanes.sh", ".github/workflows/tests.yml", "web/tests/conftest.py", "contrib/sala-web.service")
LINKS = ("https://board.example.test/items/137", "https://github.com/example-org/salamander/pull/88",
         "https://sala.example.test/#s=demo-web", "https://github.com/example-org/notes/blob/main/projects/demo.md")


def _sentence(rng: random.Random, n: int = 12) -> str:
    out = []
    for i in range(max(2, n)):
        w = rng.choice(WORDS) if i % 3 else rng.choice(VERBS)
        out.append(w)
    s = " ".join(out)
    return s[0].upper() + s[1:] + "."


def _para(rng: random.Random, scale: float, sentences: int = 2) -> str:
    """sentences of a length that follows scale (words), so the byte count moves smoothly with it"""
    return " ".join(_sentence(rng, round(rng.randint(8, 16) * scale)) for _ in range(max(1, sentences)))


def _reply_md(rng: random.Random, scale: float) -> str:
    k = max(1, round(2 * scale))
    w = lambda n: round(n * scale)  # noqa: E731
    code = "\n".join(f"$ {rng.choice(('curl --unix-socket $S http://x/api/sessions', 'systemctl --user restart sala-web.service', 'git -C ~/salamander log --oneline -3', 'uv run --frozen pytest -q'))}  # {_sentence(rng, w(5))}"
                     for _ in range(3 + k))
    rows = "\n".join(f"| `{rng.choice(PATHS)}` | {_sentence(rng, w(6))} | [board#{rng.randint(100, 150)}]({rng.choice(LINKS)}) |" for _ in range(2 + k))
    items = "\n".join(f"- **{rng.choice(WORDS)}**: {_sentence(rng, w(10))} See [{rng.choice(('the PR', 'the page', 'the item'))}]({rng.choice(LINKS)})." for _ in range(2 + k))
    return (f"{_para(rng, scale, k)}\n\n## {_sentence(rng, 4)[:-1]}\n\n{items}\n\n| file | what | where |\n|---|---|---|\n{rows}\n\n"
            f"```bash\n{code}\n```\n\n{_para(rng, scale, k)} Verified with `{rng.choice(VERBS)}` on `{rng.choice(PATHS)}`; "
            f"the rest is on {rng.choice(LINKS)}.\n")


def _tool_result(rng: random.Random, scale: float) -> str:
    n = 4 + round(12 * scale)
    kind = rng.randint(0, 2)
    if kind == 0:  # a listing with paths and sizes
        return "\n".join(f"-rw-rw-r-- 1 ada ada {rng.randint(100, 99999):6d} Oct 14 {rng.randint(10, 23)}:{rng.randint(10, 59)} {rng.choice(PATHS)}" for _ in range(n))
    if kind == 1:  # a numbered read
        return "\n".join(f"{i + 1:6d}\t{_sentence(rng, 9)}" for i in range(n))
    return "\n".join(f"{_sentence(rng, 7)} {rng.choice(LINKS)}" for _ in range(n))


def big_transcript(n: int = 200, scale: float = 1.0, seed: int = 1, first_uuid: int = 1000) -> str:
    """n display messages (one transcript line each), in cycles of five: a prompt, a reply with thinking, text and a
    tool call, the tool's result, a text-only reply, a notice from another session."""
    rng = random.Random(seed)
    lines = []
    uid = first_uuid
    tool_seq = 0
    for i in range(n):
        uid += 1
        u = f"m-{uid}"
        ts = f"2026-10-14T{10 + i // 60 % 12:02d}:{i % 60:02d}:00.000Z"
        step = i % 5
        if step == 0:
            lines.append(transcript_line("user", [{"type": "text", "text": f"{_para(rng, scale, 2)} see {rng.choice(LINKS)} and [board#{rng.randint(100, 150)}]({rng.choice(LINKS)})"}], u))
        elif step == 1:
            tool_seq += 1
            tool = rng.choice(("Bash", "Read", "Edit"))
            inp = ({"command": f"git -C /home/alex/salamander log --oneline -5 -- {rng.choice(PATHS)} && {_sentence(rng, 6)}", "description": _sentence(rng, 5)} if tool == "Bash"
                   else {"file_path": "/home/alex/salamander/" + rng.choice(PATHS)} if tool == "Read"
                   else {"file_path": "/home/alex/salamander/" + rng.choice(PATHS), "old_string": _para(rng, scale, 1), "new_string": _para(rng, scale, 2)})
            lines.append(transcript_line("assistant", [
                {"type": "thinking", "thinking": _para(rng, scale, 2)},
                {"type": "text", "text": _reply_md(rng, scale)},
                {"type": "tool_use", "id": f"toolu_{tool_seq:04d}", "name": tool, "input": inp},
            ], u, model="claude-opus-5-5"))
        elif step == 2:
            lines.append(transcript_line("user", [{"type": "tool_result", "tool_use_id": f"toolu_{tool_seq:04d}", "content": _tool_result(rng, scale),
                                                   **({"is_error": True} if i % 25 == 2 else {})}], u))
        elif step == 3:
            lines.append(transcript_line("assistant", [{"type": "text", "text": _reply_md(rng, scale * 0.6)}], u, model="claude-opus-5-5"))
        else:
            lines.append(transcript_line("user", [{"type": "text", "text": "Another Claude session sent a message:\nfrom: demo\n\n" + _para(rng, scale, 2) + f" {rng.choice(LINKS)}"}], u, meta=True))
        lines[-1] = lines[-1].replace('"timestamp": "2026-10-14T03:00:00.000Z"', f'"timestamp": "{ts}"')
    return "".join(lines)


def reset_bytes(text: str, session_id: str, n: int = 200) -> tuple[int, int]:
    """(bytes, messages) of the reset payload the stream would send for this transcript: what the page receives."""
    import tempfile
    from pathlib import Path

    from sala_web import transcript as TR
    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as f:
        f.write(text)
        p = Path(f.name)
    try:
        msgs, _ = TR.read_tail(p, session_id, n)
    finally:
        p.unlink()
    return len(json.dumps({"messages": msgs}, ensure_ascii=False).encode()), len(msgs)


def fit_scale(target_bytes: int, session_id: str, n: int = 200, seed: int = 1) -> tuple[str, float, int]:
    """A transcript whose reset payload is close to target_bytes: (text, scale, bytes)."""
    scale = 1.0
    text, got = "", 0
    for _ in range(8):
        text = big_transcript(n, scale, seed)
        got, _ = reset_bytes(text, session_id, n)
        if abs(got - target_bytes) < target_bytes * 0.03:
            break
        scale = max(0.1, scale * (target_bytes / got) ** 0.8)  # damped: part of each message does not scale
    return text, scale, got


SCOPES = {"example": ("hub", "demo", "board", "lamp", "meter", "proxy"),
          "beta": ("web", "docs", "api", "mobile", "ledger"), "gamma": ("harbor", "pantry", "kayak", "loft")}


def fleet(n: int = 44) -> list[dict]:
    """n sessions over the projects above: a front without a suffix, a -main front and a -maintainer background per project, then
    extra fronts; {"name", "role", "project"} each, roles as stackshot's `get roles` keys them."""
    out = []
    projects = [(scope, p) for scope, ps in SCOPES.items() for p in ps]
    i = 0
    while len(out) < n:
        scope, p = projects[i % len(projects)]
        slug = f"projects/{p}" if scope == "example" else f"projects/{scope}-{p}"
        k = i // len(projects)
        if k == 0:
            name, role = f"{scope}-{p}", "front"
        elif k == 1:
            name, role = f"{scope}-{p}-main", "front"
        elif k == 2:
            name, role = f"{scope}-{p}-maintainer", "back"
        else:
            name, role = f"{scope}-{p}-{('engineer', 'ops', 'review', 'scratch')[k % 4]}{k}", "front"
        out.append({"name": name, "role": role, "project": slug})
        i += 1
    return out[:n]
