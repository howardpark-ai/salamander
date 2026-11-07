#!/usr/bin/env bash
# The shared API-credit record. lib/api_credit.py (the one writer, also a command), lib/api-credit.sh
# (the shell reader, pure bash) and contrib/briefing/sdk_run.py's part in it. The record is
# ${XDG_STATE_HOME:-~/.local/state}/api-credit/state.json = {"refused_at": <epoch>, "by": "<job>", "detail": "<200 chars>"}; the
# key is used when it holds no refused_at within API_CREDIT_RETRY_S (21600 s). Checks: no record → key; a fresh refusal →
# subscription; an old one → key; the 6 h boundary; the retry override; a garbage record; a refusal text is told by "credit balance"
# in any case; the write (atomic, mode 700 directory, 600 file, detail cut at 200 characters, replaces an older record, no temp file
# left); a success clears; the shell reader and the Python reader agree on every case; sdk_run.py against a stub SDK writes the
# record on a "credit balance" refusal (result, billing_error message, exception) and clears it on a working turn, and leaves it
# alone on any other failure. Offline; the record lives in a temporary XDG_STATE_HOME that is removed pass or fail.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd); PY=$ROOT/lib/api_credit.py; SH=$ROOT/lib/api-credit.sh
fail=0; ok() { echo "  ok   $*"; }; bad() { echo "  FAIL $*"; fail=1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
exec 8<"$T"; flock -n 8   # systemd-tmpfiles ageing honours a held flock on the folder
export XDG_STATE_HOME="$T/xdg" HOME="$T/home"; mkdir -p "$HOME"
unset API_CREDIT_RETRY_S
REC=$XDG_STATE_HOME/api-credit/state.json; NOW=1800000000
rec_at() { mkdir -p "$XDG_STATE_HOME/api-credit"; printf '{"refused_at": %s, "by": "demo", "detail": "x"}\n' "$1" > "$REC"; }
rec_none() { rm -rf "$XDG_STATE_HOME"; }
py_ok() { python3 -I "$PY" check --now "$NOW"; }                  # 0 = use the key
sh_ok() { bash -c '. "$1"; api_credit_ok "$2"' _ "$SH" "$NOW"; }   # 0 = use the key

# the rule, in both readers
check() { # check <label> <want: key|sub> [VAR=value ...]; the record is already in place
    local label=$1 want=$2; shift 2
    local p s; env "$@" python3 -I "$PY" check --now "$NOW"; p=$?
    env "$@" bash -c '. "$1"; api_credit_ok "$2"' _ "$SH" "$NOW"; s=$?
    local exp=0; [ "$want" = sub ] && exp=1
    [ "$p" = "$exp" ] && [ "$s" = "$exp" ] && ok "$label: $want (python and shell agree)" || bad "$label: want $want, python=$p shell=$s"
}
rec_none;                         check "no record" key
rec_at $((NOW - 60));             check "refused 60 s ago" sub
rec_at $((NOW - 21599));          check "refused 21599 s ago" sub
rec_at $((NOW - 21600));          check "refused exactly 6 h ago" key
rec_at $((NOW - 7 * 3600));       check "refused 7 h ago" key
rec_at $((NOW + 60));             check "refused 60 s in the future (clock skew)" sub
rec_at $((NOW + 100000));         check "refused far in the future (a wrong clock never blocks the key for long)" key
rec_at $((NOW - 600));            check "refused 10 min ago, API_CREDIT_RETRY_S=300" key API_CREDIT_RETRY_S=300
rec_at $((NOW - 600));            check "refused 10 min ago, API_CREDIT_RETRY_S=900" sub API_CREDIT_RETRY_S=900
rec_at $((NOW - 600));            check "refused 10 min ago, API_CREDIT_RETRY_S=junk (the default 6 h)" sub API_CREDIT_RETRY_S=junk
rec_at $((NOW - 600));            check "refused 10 min ago, API_CREDIT_RETRY_S=0 (the default 6 h)" sub API_CREDIT_RETRY_S=0
mkdir -p "$XDG_STATE_HOME/api-credit"
printf 'not json\n' > "$REC";                                 check "garbage record" key
printf '{"by": "x"}\n' > "$REC";                              check "record without refused_at" key
printf '{"refused_at": "soon"}\n' > "$REC";                   check "refused_at not a number" key
printf '{"refused_at":%s,"by":"compact"}\n' $((NOW - 5)) > "$REC"; check "compact JSON without spaces" sub
printf '{\n  "by": "pretty",\n  "refused_at": %s,\n  "detail": ""\n}\n' $((NOW - 5)) > "$REC"; check "pretty-printed JSON, refused_at not first" sub
rec_none
env XDG_STATE_HOME= HOME="$T/home" python3 -I "$PY" check --now "$NOW"; [ $? = 0 ] && ok "empty XDG_STATE_HOME falls back to ~/.local/state (no record there)" || bad "empty XDG_STATE_HOME"
mkdir -p "$T/home/.local/state/api-credit"; printf '{"refused_at": %s}\n' $((NOW - 5)) > "$T/home/.local/state/api-credit/state.json"
env -u XDG_STATE_HOME HOME="$T/home" python3 -I "$PY" check --now "$NOW"; p=$?
env -u XDG_STATE_HOME HOME="$T/home" bash -c '. "$1"; api_credit_ok "$2"' _ "$SH" "$NOW"; s=$?
[ "$p" = 1 ] && [ "$s" = 1 ] && ok "without XDG_STATE_HOME: ~/.local/state/api-credit/state.json is read by both" || bad "default location: python=$p shell=$s"
rm -rf "$T/home/.local"

# what a refusal looks like
for t in "Your credit balance is too low to access the Anthropic API" "CREDIT BALANCE is too low" "error: Credit Balance Is Too Low."; do
    python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import api_credit as a; sys.exit(0 if a.is_refusal(sys.argv[2]) else 1)' "$ROOT/lib" "$t" \
        && ok "is_refusal: \"$t\"" || bad "is_refusal missed: $t"
done
for t in "rate limit exceeded" "" "credit card declined"; do
    python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import api_credit as a; sys.exit(1 if a.is_refusal(sys.argv[2]) else 0)' "$ROOT/lib" "$t" \
        && ok "is_refusal says no to: \"$t\"" || bad "is_refusal wrongly matched: $t"
done

# the write
rec_none
python3 -I "$PY" refuse "briefing defunct" "Your credit balance is too low" || bad "refuse failed"
[ -f "$REC" ] && ok "refuse creates the record" || bad "no record after refuse"
[ "$(stat -c %a "$XDG_STATE_HOME/api-credit")" = 700 ] && ok "the directory is mode 700" || bad "directory mode $(stat -c %a "$XDG_STATE_HOME/api-credit")"
[ "$(stat -c %a "$REC")" = 600 ] && ok "the file is mode 600" || bad "file mode $(stat -c %a "$REC")"
python3 -I - "$REC" "$NOW" <<'PY' && ok "the record is {refused_at (an int, now), by, detail} and nothing else" || bad "record content: $(cat "$REC")"
import json, sys, time
d = json.load(open(sys.argv[1]))
assert sorted(d) == ["by", "detail", "refused_at"], d
assert isinstance(d["refused_at"], int) and abs(d["refused_at"] - time.time()) < 60, d
assert d["by"] == "briefing defunct" and d["detail"] == "Your credit balance is too low", d
PY
[ -z "$(ls -A "$XDG_STATE_HOME/api-credit" | grep -v '^state.json$')" ] && ok "no temp file left beside the record" || bad "left over: $(ls -A "$XDG_STATE_HOME/api-credit")"
long=$(python3 -c 'print("x" * 500)')
python3 -I "$PY" refuse job "$long"
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert len(d["detail"])==200, len(d["detail"])' "$REC" && ok "the detail is cut to 200 characters" || bad "detail length"
python3 -I "$PY" refuse job2 "second"
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["by"]=="job2" and d["detail"]=="second", d' "$REC" && ok "a new refusal replaces the old record" || bad "replace: $(cat "$REC")"
python3 -I "$PY" refuse multi "line one
line two"
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["detail"]=="line one line two", d' "$REC" && ok "a multi-line refusal is one line in the record" || bad "multi-line: $(cat "$REC")"
python3 -I "$PY" show | grep -q '"by": "multi"' && ok "show prints the record" || bad "show"
bash -c '. "$1"; api_credit_ok' _ "$SH"; [ $? = 1 ] && ok "the shell reader sees the Python writer's record as fresh (the real clock)" || bad "shell reader of a fresh write"
bash -c '. "$1"; api_credit_when_local' _ "$SH" | grep -q 'refused at .* by multi; the key is tried again after ' && ok "api_credit_when_local names when and by whom, and when the key is tried again" || bad "when_kst: $(bash -c '. "$1"; api_credit_when_local' _ "$SH")"
bash -c '. "$1"; api_credit_refuse shelljob "from the shell"; api_credit_ok' _ "$SH"; [ $? = 1 ] && python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["by"]=="shelljob", d' "$REC" && ok "api_credit_refuse (shell) writes through the same writer" || bad "shell refuse"
# the directory exists with another mode (the other jobs may have made it): the write works and leaves its mode alone
chmod 755 "$XDG_STATE_HOME/api-credit"; python3 -I "$PY" refuse again x && [ "$(stat -c %a "$XDG_STATE_HOME/api-credit")" = 755 ] && ok "an existing directory keeps its mode" || bad "existing directory"
chmod 700 "$XDG_STATE_HOME/api-credit"

# the clear
python3 -I "$PY" clear; [ ! -e "$REC" ] && ok "clear removes the record" || bad "clear left the record"
python3 -I "$PY" clear && ok "clear with no record is not an error" || bad "clear with no record failed"
python3 -I "$PY" refuse j x; bash -c '. "$1"; api_credit_clear' _ "$SH"; [ ! -e "$REC" ] && ok "api_credit_clear (shell) removes it too" || bad "shell clear"
python3 -I "$PY" show | grep -q 'no known refusal' && ok "show with no record" || bad "show with none"
python3 -I "$PY" bogus 2>/dev/null; [ $? = 2 ] && ok "an unknown command is a usage error (2)" || bad "usage exit"

# sdk_run.py against a stub SDK: STUB_MODE = ok | credit-result | billing-error | credit-exception | other-result | other-exception
mkdir -p "$T/stub/claude_agent_sdk"
cat > "$T/stub/claude_agent_sdk/__init__.py" <<'PY'
import os
from dataclasses import dataclass, field


class ProcessError(Exception):
    def __init__(self, msg, stderr="", exit_code=1):
        super().__init__(msg); self.stderr = stderr; self.exit_code = exit_code


@dataclass
class ClaudeAgentOptions:
    model: str = ""; allowed_tools: list = field(default_factory=list); mcp_servers: dict = field(default_factory=dict)
    strict_mcp_config: bool = False; setting_sources: list = field(default_factory=list); settings: object = None
    system_prompt: object = None; cwd: object = None; env: dict = field(default_factory=dict)


@dataclass
class TextBlock: text: str
@dataclass
class AssistantMessage: content: list; model: str = "m"; parent_tool_use_id: object = None; error: object = None; usage: object = None; message_id: object = None; stop_reason: object = None; session_id: object = None; uuid: object = None
@dataclass
class ResultMessage: subtype: str; is_error: bool; result: str


async def query(prompt, options):
    mode = os.environ["STUB_MODE"]
    if mode == "ok":
        yield AssistantMessage([TextBlock("hi")]); yield ResultMessage("success", False, "digest")
    elif mode == "credit-result":
        yield ResultMessage("success", True, "Your credit balance is too low to access the Anthropic API.")
    elif mode == "billing-error":
        yield AssistantMessage([TextBlock("Credit balance is too low")], error="billing_error"); yield ResultMessage("success", True, "Credit balance is too low")
    elif mode == "credit-exception":
        raise ProcessError("Command failed with exit code 1", stderr="Error: Credit balance is too low", exit_code=1)
    elif mode == "other-result":
        yield ResultMessage("error_max_turns", True, "ran out of turns")
    elif mode == "other-exception":
        raise ProcessError("Command failed with exit code 1", stderr="boom", exit_code=1)
PY
printf 'sk-test-not-a-key\n' > "$T/key"
sdk() { # sdk <mode> [args…]: the real sdk_run.py against the stub; prints its exit code
    local mode=$1; shift
    STUB_MODE=$mode PYTHONPATH="$T/stub" python3 -B "$ROOT/contrib/briefing/sdk_run.py" --model sonnet --key-file "$T/key" --workspace-file "" --cwd "$T" "$@" < /dev/null > "$T/sdk.out" 2> "$T/sdk.err"
    echo $?
}
rec_none
[ "$(sdk credit-result --by "briefing defunct")" = 1 ] && python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["by"]=="briefing defunct" and "credit balance" in d["detail"].lower(), d' "$REC" \
    && ok "sdk_run.py: an error result saying \"credit balance\" exits 1 and writes the record (by = --by)" || bad "credit-result: $(cat "$T/sdk.err") / $(cat "$REC" 2>/dev/null)"
[ "$(sdk ok)" = 0 ] && [ ! -e "$REC" ] && ok "sdk_run.py: a working turn exits 0 and removes the record" || bad "ok clears: $(cat "$T/sdk.err") / $(ls "$XDG_STATE_HOME/api-credit" 2>/dev/null)"
rec_none
[ "$(sdk billing-error --by j2)" = 1 ] && python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["by"]=="j2", d' "$REC" && ok "sdk_run.py: a billing_error assistant message writes the record" || bad "billing-error: $(cat "$T/sdk.err")"
rec_none
[ "$(sdk credit-exception --by j3)" = 1 ] && python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["by"]=="j3" and "credit balance" in d["detail"].lower(), d' "$REC" && ok "sdk_run.py: an SDK exception whose stderr says \"credit balance\" writes the record" || bad "credit-exception: $(cat "$T/sdk.err")"
rec_at $((NOW - 60)); before=$(cat "$REC")
[ "$(sdk other-result)" = 1 ] && [ "$(cat "$REC")" = "$before" ] && ok "sdk_run.py: any other error result leaves the record as it was" || bad "other-result touched the record"
[ "$(sdk other-exception)" = 1 ] && [ "$(cat "$REC")" = "$before" ] && ok "sdk_run.py: any other exception leaves the record as it was" || bad "other-exception touched the record"
rec_none
[ "$(sdk other-exception)" = 1 ] && [ ! -e "$REC" ] && ok "sdk_run.py: any other failure with no record writes none" || bad "other-exception wrote a record"
rec_none
[ "$(sdk credit-result)" = 1 ] && python3 -I -c 'import json,sys; assert json.load(open(sys.argv[1]))["by"]=="sdk_run"' "$REC" && ok "sdk_run.py: --by defaults to sdk_run" || bad "default --by"
grep -q 'sk-test-not-a-key' "$T/sdk.out" "$T/sdk.err" "$REC" && bad "the key's value reached the output or the record" || ok "the key's value is in no output and not in the record"

exit $fail
