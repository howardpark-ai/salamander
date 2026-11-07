"""Sidebar grouping: scopes from session names, projects inside them, clean project titles."""

from sala_web import sessions as S


def sess(name, sid=None):
    return S.Session(pid=1, session_id=sid or name, name=name, cwd="/tmp", status="idle", tmux="")


def test_scope_from_name_prefix():
    assert S.session_scope("example-lamp-main") == "example"
    assert S.session_scope("beta-docs") == "beta"
    assert S.session_scope("gamma-harbor") == "gamma"
    assert S.session_scope("scratch-20260101-oak") == "other"
    assert S.session_scope("example") == "example"


def test_project_titles():
    assert S.project_title("projects/beta-docs", "beta") == "docs"
    assert S.project_title("projects/beta-mobile", "beta") == "mobile"
    assert S.project_title("projects/ops", "example") == "ops"
    assert S.project_title("projects/stackshot", "example") == "stackshot"
    assert S.project_title("projects/harbor-room-b", "gamma") == "harbor-room-b"
    assert S.project_title("projects/logo-mark", "beta") == "logo-mark"
    assert S.project_title("projects/beta", "beta") == "beta"  # nothing left after the prefix: keep it


def test_scopes_projects_sessions():
    roles = {
        "beta-docs": {"role": "front", "project": "projects/beta-docs"},
        "beta-docs-main": {"role": "front", "project": "projects/beta-docs"},
        "example-board": {"role": "front", "project": "projects/stackshot"},
        "example-lamp": {"role": "front", "project": "projects/gbrain"},
        "example-ops": {"role": "front", "project": "projects/ops"},
        "gamma-harbor": {"role": "front", "project": "projects/harbor-room-b"},
        # a tie (one gamma, one beta): the scope of the first by name wins
        "gamma-mixed": {"role": "front", "project": "projects/mixed"},
        "beta-mixed": {"role": "front", "project": "projects/mixed"},
        # the majority beats the first by name
        "example-maj": {"role": "front", "project": "projects/maj"},
        "gamma-maj-a": {"role": "front", "project": "projects/maj"},
        "gamma-maj-b": {"role": "back", "project": "projects/maj"},
        "weird-thing": {"role": "front", "project": "projects/weird"},
    }
    live = [sess(n) for n in roles] + [sess("scratch-1"), sess("example-loose")]
    out = S.group_sessions(live, roles)
    assert [sc["key"] for sc in out] == ["example", "beta", "gamma", "other", "Unregistered"]
    by = {sc["key"]: sc for sc in out}
    assert [(g["title"], g["key"]) for g in by["example"]["groups"]] == [
        ("gbrain", "projects/gbrain"), ("ops", "projects/ops"), ("stackshot", "projects/stackshot")]
    assert [(g["title"], g["key"]) for g in by["beta"]["groups"]] == [("docs", "projects/beta-docs"),
                                                                       ("mixed", "projects/mixed")]
    assert [s["name"] for s in by["beta"]["groups"][0]["sessions"]] == ["beta-docs", "beta-docs-main"]
    assert [g["key"] for g in by["gamma"]["groups"]] == ["projects/harbor-room-b", "projects/maj"]
    assert [g["title"] for g in by["other"]["groups"]] == ["weird"]
    # Unregistered: one flat group, not split by scope
    assert by["Unregistered"]["flat"] is True
    assert [s["name"] for s in by["Unregistered"]["groups"][0]["sessions"]] == ["example-loose", "scratch-1"]


def test_an_unknown_role_sorts_after_back_and_breaks_nothing():
    roles = {"example-x-a": {"role": "legacy", "project": "projects/x"},
             "example-x-b": {"role": "back", "project": "projects/x"},
             "example-x-main": {"role": "front", "project": "projects/x"}}
    out = S.group_sessions([sess(n) for n in roles], roles)
    assert [s["name"] for s in out[0]["groups"][0]["sessions"]] == ["example-x-main", "example-x-b", "example-x-a"]
    assert [r["name"] for r in S.overview_rows([sess(n) for n in roles], roles)] == ["example-x-main", "example-x-b", "example-x-a"]


def test_live_tmux_name_replaces_the_launch_name():
    assert S._with_live_name("55:@60.%61", {"%61": "demo-web"}) == "demo-web:@60.%61"
    assert S._with_live_name("55:@60.%61", {}) == "55:@60.%61"
    assert S._with_live_name("", {"%61": "x"}) == ""


def test_proc_lane_reads_the_environment(tmp_path, monkeypatch):
    team = tmp_path / ".claude-team"
    team.mkdir()
    monkeypatch.setattr(S, "LANE_DIRS", {"subscription-2": team})
    envs = {1: b"PATH=/bin\0ANTHROPIC_API_KEY=x\0", 2: b"PATH=/bin\0", 3: b"CLAUDE_CONFIG_DIR=" + str(team).encode() + b"\0",
            4: b"CLAUDE_CONFIG_DIR=/elsewhere\0", 5: b"ANTHROPIC_API_KEY=\0",
            6: b"CLAUDE_CODE_ENTRYPOINT=sdk-py\0ANTHROPIC_API_KEY=x\0", 7: b"CLAUDE_CODE_ENTRYPOINT=cli\0",
            # the two AWS lanes: the flag alone, as sala's proc_lane reads them
            10: b"PATH=/bin\0AWS_PROFILE=example-bedrock\0CLAUDE_CODE_USE_BEDROCK=1\0AWS_REGION=us-east-1\0",
            11: b"PATH=/bin\0CLAUDE_CODE_USE_ANTHROPIC_AWS=1\0ANTHROPIC_AWS_WORKSPACE_ID=wrkspc_01EXAMPLE\0AWS_REGION=us-east-1\0",
            12: b"CLAUDE_CODE_USE_ANTHROPIC_AWS=1\0CLAUDE_CODE_USE_BEDROCK=1\0",             # Bedrock wins the routing, so it wins here
            13: b"CLAUDE_CODE_USE_ANTHROPIC_AWS=1\0ANTHROPIC_API_KEY=x\0",                   # a key beside the flag does not make it api
            14: b"CLAUDE_CODE_USE_BEDROCK=0\0CLAUDE_CODE_USE_ANTHROPIC_AWS=\0",              # only the exact value 1 counts: max
            15: b"CLAUDE_CODE_USE_BEDROCK=10\0XCLAUDE_CODE_USE_ANTHROPIC_AWS=1\0",           # not a prefix match, not a suffix match: max
            16: b"CLAUDE_CODE_ENTRYPOINT=sdk-py\0CLAUDE_CODE_USE_BEDROCK=1\0",               # an SDK entrypoint is asked first
            17: b"CLAUDE_CODE_USE_ANTHROPIC_AWS=1\0CLAUDE_CONFIG_DIR=" + str(team).encode() + b"\0"}
    real = S.Path

    class FakePath(type(real())):
        def read_bytes(self):
            pid = int(str(self).split("/")[2]) if str(self).startswith("/proc/") else None
            if pid is None:
                return super().read_bytes()
            if pid not in envs:
                raise OSError
            return envs[pid]

    monkeypatch.setattr(S, "Path", FakePath)
    assert [S.proc_lane(p) for p in (1, 2, 3, 4, 5, 6, 7, 9)] == [
        "api", "subscription-1", "subscription-2", "other", "subscription-1", "sdk", "subscription-1", None]
    assert [S.proc_lane(p) for p in (10, 11, 12, 13, 14, 15, 16, 17)] == [
        "bedrock", "aws-platform", "bedrock", "aws-platform", "subscription-1", "subscription-1", "sdk", "aws-platform"]
