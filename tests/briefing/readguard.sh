#!/usr/bin/env bash
# The read guard, contrib/briefing/guard.py, a PreToolUse hook that refuses a portal
# call that is not plainly one of the five Gmail reads BEFORE it runs. Checks the hook's decisions through its real
# command (stdin JSON in, deny JSON or nothing out): the shapes of real calls pass (the string
# literals of the digests' own logs replaced by "xxx", the structure kept); a send, a
# draft, a label change, a Drive and a Calendar call, a computed access, an alias, a mixed read+write, a comment-hidden
# write, a string-concatenated name and the other evasions are each refused with a reason; portal_codemode_search is
# allowed; non-portal tools pass untouched; a write-named Workspace tool is refused by name; malformed input refuses.
# Then the wiring: run_claude hands the hook to claude -p (--settings) and to the SDK runner, a plain claude run gets
# nothing; and the stream log's reading: a refused call counts no Gmail read, is no write, and is named as refused in
# cron.log and under the digest. A fake `claude`, a fake runner, posting stubbed; offline.
set -u
export BRIEFING_GMAIL_CONNECTOR=demo   # a made-up connector word (config.example): the tools are mcp__claude_ai_Google_Workspace_demo__* and the portal's gdemo_*
ROOT=$(cd "$(dirname "$0")/../.." && pwd); D=$ROOT/contrib/briefing
fail=0; ok() { echo "  ok   $*"; }; bad() { echo "  FAIL $*"; fail=1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/bin" "$T/logs"
EX=mcp__mcp-portal__portal_codemode_execute
SEARCH=mcp__mcp-portal__portal_codemode_search

# hook <tool> <code|-> : runs guard.py as the CLI does; prints "deny <reason>" or "allow"
hook() {
    local tool=$1 code=$2 out
    if [ "$code" = - ]; then out=$(printf '{"tool_name":"%s","tool_input":{}}' "$tool" | python3 -I "$D/guard.py" --log "$T/guard.log")
    else out=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":sys.argv[1],"tool_input":{"code":sys.argv[2]}}))' "$tool" "$code" \
                 | python3 -I "$D/guard.py" --log "$T/guard.log"); fi
    if [ -z "$out" ]; then echo allow
    else python3 -c 'import json,sys; d=json.loads(sys.stdin.read())["hookSpecificOutput"]; assert d["permissionDecision"]=="deny" and d["hookEventName"]=="PreToolUse"; print("deny", d["permissionDecisionReason"])' <<<"$out"; fi
}
allow() { # allow <label> <code>
    local r; r=$(hook "$EX" "$2")
    [ "$r" = allow ] && ok "allowed: $1" || bad "allowed: $1 -> $r"
}
deny() { # deny <label> <code> <pattern in the reason>
    local r; r=$(hook "$EX" "$2")
    case "$r" in "deny [briefing-guard]"*"$3"*) ok "refused: $1 ($3)" ;; *) bad "refused: $1 -> $r" ;; esac
}

# real calls, string literals masked (the digests' own code shapes: search, batch content, content)
allow "defunct: search" "async () => await codemode.gdemo_search_gmail_messages({ query: 'xxx', page_size: 50 })"
allow "defunct: batch, length cap" 'async () => { const ids=["xxx","xxx","xxx"]; const r = await codemode.gdemo_get_gmail_messages_content_batch({ message_ids: ids }); const s = typeof r==='"'"'xxx'"'"'?r:JSON.stringify(r); return s.length>30000? s.slice(0,30000):s; }'
allow "defunct: batch, split/map/regex" "async () => { const ids=[\"xxx\",\"xxx\"]; const r = await codemode.gdemo_get_gmail_messages_content_batch({ message_ids: ids }); const s = typeof r==='xxx'?r:(r.result||JSON.stringify(r)); return s.split(/\\n---\\n/).map(m=>{const g=k=>(m.match(new RegExp('xxx'+k+'xxx','xxx'))||[])[1]; const b=(m.split('xxx')[1]||'xxx').replace(/\\s+/g,'xxx').slice(0,150); return [g('xxx'),g('xxx'),g('xxx'),g('xxx'),g('xxx'),b].join('xxx')}).join('xxx'); }"
allow "summary: search" 'async () => await codemode.gdemo_search_gmail_messages({ query: "xxx", page_size: 50 })'
allow "summary: batch over lines" $'async () => {\nconst ids="xxx".split("xxx");\nconst r = await codemode.gdemo_get_gmail_messages_content_batch({message_ids: ids});\nconst s = typeof r==="xxx"?r:JSON.stringify(r);\nreturn s.replace(/\\n\\s*\\n/g,"xxx").slice(0,30000);\n}'
allow "summary: two batches, for-of, nested arrows" $'async () => {\nconst ids="xxx".split("xxx");\nconst rs = await Promise.all([codemode.gdemo_get_gmail_messages_content_batch({message_ids: ids.slice(0,25)}),codemode.gdemo_get_gmail_messages_content_batch({message_ids: ids.slice(25)})]);\nconst out=[];\nfor (const r of rs){ const s=typeof r==="xxx"?r:(r.result||JSON.stringify(r));\n for (const m of s.split(/\\n---\\n\\nMessage ID: |^Retrieved \\d+ messages:\\n\\nMessage ID: /)) { \n  const g=k=>((m.match(new RegExp("xxx"+k+"xxx","xxx"))||[])[1]||"xxx");\n  const b=(m.split("xxx")[1]||"xxx").replace(/https?:\\S+/g,"xxx").replace(/\\s+/g,"xxx").slice(0,220);\n  out.push([m.slice(0,16),g("xxx"),g("xxx"),g("xxx"),b].join("xxx"));\n }}\nreturn out.join("xxx");\n}'
allow "summary: content x4 via map" $'async () => {\nconst r = await Promise.all(["xxx","xxx","xxx","xxx"].map(id=>codemode.gdemo_get_gmail_message_content({message_id:id})));\nreturn r.map(x=>{const s=typeof x==="xxx"?x:(x.result||JSON.stringify(x));return (s.split("xxx")[1]||s).replace(/https?:\\S+/g,"xxx").replace(/\\s+/g,"xxx").slice(0,1500)}).join("xxx");\n}'
allow "summary: content, regex capture" 'async () => { const x = await codemode.gdemo_get_gmail_message_content({message_id:"xxx"}); const s=typeof x==="xxx"?x:(x.result||JSON.stringify(x)); return (s.match(/url=([^&\s>]+)/)||[])[1]; }'
# the two thread reads and the prompt's examples
allow "thread read" 'async () => await codemode.gdemo_get_gmail_thread_content({ thread_id: "a" })'
allow "threads batch in Promise.all" 'async () => Promise.all([codemode.gdemo_get_gmail_threads_content_batch({ thread_ids: ["a", "b"] })])'
allow "allSettled, try/catch, template with \${}" 'async () => { try { const q = `is:unread newer_than:${1}d`; const rs = await Promise.allSettled([codemode.gdemo_search_gmail_messages({ query: q })]); return rs.map(r => r.status === "fulfilled" ? r.value : String(r.reason)); } catch (e) { return e.message; } }'
allow "for(;;) chunks, while, switch, function expression" 'async () => { const ids = ["a","b"]; const chunks = []; for (let i = 0; i < ids.length; i += 25) { chunks.push(ids.slice(i, i + 25)); } let n = 0; while (n < 1) { n++; } const rs = await Promise.all(chunks.map(c => codemode.gdemo_get_gmail_messages_content_batch({ message_ids: c }))); switch (typeof rs) { case "string": return rs; default: return rs.filter(function (x) { return x; }).reduce((a, b) => a + String(b).length, 0); } }'

# refused: the writes and the evasions, each with the reason naming it
deny "a send" 'async () => await codemode.gdemo_send_gmail_message({ to: "x@example.com", subject: "s", body: "b" })' "codemode.gdemo_send_gmail_message: not one of the five Gmail reads"
deny "a draft" 'async () => await codemode.gdemo_draft_gmail_message({ to: "x@example.com", subject: "s", body: "b" })' "gdemo_draft_gmail_message: not one"
deny "a label change" 'async () => await codemode.gdemo_modify_gmail_message_labels({ message_id: "a", add_label_ids: ["x"] })' "gdemo_modify_gmail_message_labels: not one"
deny "a Drive call" 'async () => await codemode.gdemo_create_drive_file({ name: "n" })' "gdemo_create_drive_file: not one"
deny "a Calendar call" 'async () => await codemode.gdemo_manage_event({ action: "create" })' "gdemo_manage_event: not one"
deny "another server" 'async () => await codemode.stackshot_brief({})' "codemode.stackshot_brief: not one"
deny "a Gmail read-like tool not on the list" 'async () => await codemode.gdemo_list_gmail_labels({})' "gdemo_list_gmail_labels: not one"
deny "codemode[x](...)" 'async () => { const k = "x"; return await codemode[k]({}); }' "used other than as codemode.<gmail read>"
deny "codemode[\"gdemo_\" + ...]" 'async () => await codemode["gdemo_" + "send_gmail_message"]({ to: "x" })' "inside a literal"
deny "const c = codemode; c.…" 'async () => { const c = codemode; return await c.gdemo_send_gmail_message({}); }' "used other than as codemode.<gmail read>"
deny "a mixed read + write" 'async () => [await codemode.gdemo_get_gmail_thread_content({ thread_id: "a" }), await codemode.gdemo_send_gmail_message({})]' "gdemo_send_gmail_message: not one"
deny "a comment-hidden call" 'async () => { /* codemode.gdemo_search_gmail_messages( */ return await codemode.gdemo_send_gmail_message({}) /* ) */ }' "gdemo_send_gmail_message: not one"
deny "a comment between name and call" 'async () => await codemode.gdemo_send_gmail_message /* read */ ({})' "gdemo_send_gmail_message: not one"
deny "a string-concatenated name" 'async () => { const n = "gdemo_send" + "_gmail_message"; return await codemode[n]({}); }' "inside a literal"
deny "destructuring codemode" 'async () => { const { gdemo_send_gmail_message: f } = codemode; return await f({}); }' "outside codemode.<gmail read>"
deny "passing codemode to a function" 'async () => { const f = (o) => o.gdemo_send_gmail_message({}); return await f(codemode); }' "outside codemode.<gmail read>"
deny "Object.keys(codemode)" 'async () => Object.keys(codemode)' "used other than as codemode.<gmail read>"
deny "Object.entries(codemode)" 'async () => Object.entries(codemode).map(e => e[1]({}))' "used other than as codemode.<gmail read>"
deny "a default parameter" 'async () => { const f = (a = codemode) => a; return f(); }' "used other than as codemode.<gmail read>"
deny "eval" 'async () => eval("1")' 'the name `eval`'
deny "Function(...)" 'async () => Function("return 1")()' 'the name `Function`'
deny ".constructor" 'async () => (async()=>{}).constructor("return 1")()' 'the name `constructor`'
deny "dynamic import" 'async () => (await import("x")).y' 'the keyword `import`'
deny "this / globalThis / arguments" 'async () => globalThis' 'the name `globalThis`'
BS='\'   # a JavaScript identifier may spell a letter as a unicode escape; the backslash is built here, never typed as \-u
deny "a unicode escape in the identifier (c${BS}u006fdemode)" "async () => await c${BS}u006fdemode.gdemo_send_gmail_message({})" "a backslash outside a literal"
deny "a non-ASCII lookalike identifier" 'async () => { const ｃodemode = 1; return 1 }' "a non-ASCII character"
deny "codemode?.read(...)" 'async () => await codemode?.gdemo_search_gmail_messages({})' "used other than as codemode.<gmail read>"
deny "the read taken as a value" 'async () => { const f = codemode.gdemo_search_gmail_messages; return await f({}); }' "used other than as codemode.<gmail read>"
deny "read.call(...)" 'async () => await codemode.gdemo_search_gmail_messages.call(null, {})' "used other than as codemode.<gmail read>"
deny "a parameter on the arrow" 'async (c) => await c.gdemo_search_gmail_messages({})' "not one \`async () => ...\` arrow function"
deny "not an arrow function" 'await codemode.gdemo_search_gmail_messages({})' "not one \`async () => ...\` arrow function"
deny "a second statement after the function" 'async () => { return 1; }; codemode.gdemo_send_gmail_message({})' "code after the arrow function"
deny "a free identifier from the enclosing scope" 'async () => await env.codemode.gdemo_search_gmail_messages({})' 'the unknown name `env`'
deny "a free identifier used after its block" 'async () => { { const env = 1; } return Object.values(env); }' 'the unknown name `env`'
deny "a parameter used after its arrow" 'async () => { [1].map(env => env); return env; }' 'the unknown name `env`'
deny "a computed index that is not a number" 'async () => { const a = [1]; const i = 0; return a[i]; }' "not a single numeric index"
deny "codemode.tools() (search only)" 'async () => (await codemode.tools()).map(t => t.name)' "codemode.tools: not one"
deny "a write inside a template's \${}" 'async () => `${await codemode.gdemo_send_gmail_message({})}`' "gdemo_send_gmail_message: not one"
deny "the name in a literal" 'async () => { const n = "codemode"; return n; }' "inside a literal"
deny "an unterminated string" 'async () => { const s = "abc' "an unterminated string literal"
deny "setTimeout / fetch / process" 'async () => fetch("https://example.com")' 'the name `fetch`'
r=$(hook "$EX" ''); case "$r" in "deny "*"Refused: no code string"*) ok "refused: an empty code string" ;; *) bad "empty code: $r" ;; esac
r=$(hook "$EX" -); case "$r" in "deny "*"Refused: no code string"*) ok "refused: a missing code argument" ;; *) bad "missing code: $r" ;; esac
r=$(printf '{"tool_name":"%s","tool_input":{"code":5}}' "$EX" | python3 -I "$D/guard.py"); case "$r" in *'"deny"'*"Refused: no code string"*) ok "refused: a non-string code argument" ;; *) bad "code 5: $r" ;; esac
r=$(printf 'not json' | python3 -I "$D/guard.py"); case "$r" in *'"deny"'*"hook input could not be read"*) ok "refused: unreadable hook input (fails closed)" ;; *) bad "not json: $r" ;; esac

# the other tools
[ "$(hook "$SEARCH" 'async () => (await codemode.tools()).filter(t => t.name.includes("gmail"))')" = allow ] && ok "portal_codemode_search allowed (it only lists tools)" || bad "search refused"
for t in Read Write Bash ToolSearch Edit; do [ "$(hook $t -)" = allow ] || bad "$t touched"; done; ok "Read, Write, Bash, ToolSearch, Edit: untouched"
for t in mcp__claude_ai_Google_Workspace_demo__search_gmail_messages mcp__claude_ai_Google_Workspace_demo__get_gmail_messages_content_batch mcp__claude_ai_Google_Workspace_demo__get_gmail_thread_content; do
    [ "$(hook $t -)" = allow ] || bad "$t refused"; done; ok "the direct connector's Gmail reads: untouched"
r=$(hook mcp__claude_ai_Google_Workspace_demo__send_gmail_message -); case "$r" in "deny "*"can write (send)"*) ok "a Workspace write tool refused by name (send)" ;; *) bad "send tool: $r" ;; esac
r=$(hook mcp__claude_ai_Google_Workspace_demo__draft_gmail_message -); case "$r" in "deny "*"can write (draft)"*) ok "… (draft)" ;; *) bad "draft tool: $r" ;; esac
r=$(hook mcp__claude_ai_Google_Drive__share_file -); case "$r" in "deny "*"can write (share)"*) ok "… (share, another connector)" ;; *) bad "share tool: $r" ;; esac
r=$(hook mcp__mcp-portal__portal_toggle_servers -); case "$r" in "deny "*"a portal tool the briefing never uses"*) ok "the portal's own toggles refused" ;; *) bad "toggle: $r" ;; esac
grep -q " $EX deny \[\] refused: codemode.gdemo_send_gmail_message" "$T/guard.log" && grep -q " $EX allow \[gdemo_search_gmail_messages\] gmail reads only" "$T/guard.log" \
    && ! grep -q 'x@example.com\|xxx' "$T/guard.log" && ok "guard.log: one line per decision with the names, never the code" || bad "guard.log: $(head -3 "$T/guard.log")"

# the wiring: what run_claude hands claude -p and the SDK runner, and what a plain claude run does not get.
# runhook.py does what the real CLI does with --settings: for each tool_use of the stream it runs the PreToolUse hook
# command the settings JSON names (the fakes call it when FAKE_HOOK names them: cli, sdk), so guard.log gets its lines
# only when the hook really was handed over (the load check).
cat > "$T/bin/runhook.py" <<'PY'
import json,re,shlex,subprocess,sys
stream, argv = sys.argv[1], sys.argv[2:]
if "--settings" not in argv: sys.exit(0)
h = json.loads(argv[argv.index("--settings") + 1])["hooks"]["PreToolUse"][0]
for line in open(stream, encoding="utf-8"):
    d = json.loads(line)
    for c in (d.get("message") or {}).get("content") or []:
        if d.get("type") == "assistant" and c.get("type") == "tool_use" and re.fullmatch(h["matcher"], c["name"]):
            subprocess.run(shlex.split(h["hooks"][0]["command"]), input=json.dumps({"tool_name": c["name"], "tool_input": c.get("input")}),
                           text=True, capture_output=True)
PY
cat > "$T/bin/claude" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_DIR/claude-argv"; env > "$FAKE_DIR/claude-env"
[ -n "${FAKE_STREAM:-}" ] && cat "$FAKE_STREAM"
case " ${FAKE_HOOK:-} " in *" cli "*) [ -n "${FAKE_STREAM:-}" ] && python3 "$FAKE_DIR/bin/runhook.py" "$FAKE_STREAM" "$@" ;; esac
if [ -n "${FAKE_RESULT:-}" ]; then printf '%s\n' "$FAKE_RESULT"; else printf '%s\n' '{"type":"result","result":"*digest*\n• a line"}'; fi
FAKE
cat > "$T/bin/sdk" <<'FAKE'
#!/usr/bin/env bash
# fake runner: one portal read; FAKE_SDK_FAIL=1 makes it end without a result (exit 1), so claude -p reruns the turn
printf '%s\n' "$@" > "$FAKE_DIR/sdk-argv"; cat >/dev/null
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t","name":"mcp__mcp-portal__portal_codemode_execute","input":{"code":"async () => await codemode.gdemo_search_gmail_messages({ query: \"is:unread\" })"}}]}}' > "$FAKE_DIR/sdk-stream"
cat "$FAKE_DIR/sdk-stream"
case " ${FAKE_HOOK:-} " in *" sdk "*) python3 "$FAKE_DIR/bin/runhook.py" "$FAKE_DIR/sdk-stream" "$@" ;; esac
[ -n "${FAKE_SDK_FAIL:-}" ] && { echo "sdk_run: the turn ended without a result" >&2; exit 1; }
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"*digest from sdk*"}'
FAKE
chmod +x "$T/bin/claude" "$T/bin/sdk"
printf 'sk-test-not-a-key\n' > "$T/key"
run() { # run <stream|""> [VAR=value ...]: run_claude + deliver in a fresh bash; prints calls= writes= refused= deliver=
    local stream=$1; shift
    rm -f "$T"/claude-argv "$T"/sdk-argv "$T/posts" "$T/logs"/*
    env -u CLAUDE_CONFIG_DIR -u BRIEFING_BACKEND HOME="$T/home" XDG_STATE_HOME="$T/xdg" FAKE_DIR="$T" FAKE_STREAM="$stream" FAKE_HOOK="cli sdk" BRIEFING_LOGDIR="$T/logs" \
        BRIEFING_API_KEY_FILE="$T/key" BRIEFING_SDK_CMD="$T/bin/sdk" BRIEFING_SDK_MCP_CONFIG=/x/api-mcp.json SALA_HEARTBEAT_NAME=host-a SALA_CONFIG="$T/no-config" "$@" bash -c '
        . "$1/lib.sh" 2>/dev/null
        CLAUDE_BIN=$2/bin/claude POSTS=$2/posts
        post_slack() { printf "%s\n" "$1" > "$POSTS"; }
        sleep() { :; }   # run_claude_retry waits 45 s before its retry
        ${RUN:-run_claude} job "a prompt"; echo "calls=$GMAIL_CALLS writes=$PORTAL_WRITES refused=$PORTAL_REFUSED execs=$PORTAL_EXECS gained=$GUARD_LINES_GAINED"
        deliver job "Morning Email Summary"; echo "deliver=$?"
    ' _ "$D" "$T"
}
settings_of() { # settings_of <argv file>: the JSON after --settings, or nothing
    python3 -c 'import sys; a=open(sys.argv[1]).read().split("\n"); print(a[a.index("--settings")+1] if "--settings" in a else "")' "$1"
}
check_settings() { # check_settings <label> <json>
    python3 - "$D/guard.py" "$T/logs/guard.log" "$2" <<'PY' && ok "$1: --settings loads guard.py as a PreToolUse hook on mcp__.* with the log beside the stream logs" || bad "$1: --settings JSON: $2"
import json,shlex,sys
d = json.loads(sys.argv[3]); h = d["hooks"]["PreToolUse"]
assert len(h) == 1 and h[0]["matcher"] == "mcp__.*" and len(h[0]["hooks"]) == 1, h
c = h[0]["hooks"][0]; assert c["type"] == "command", c
argv = shlex.split(c["command"]); assert argv[:2] == ["python3", "-I"] and argv[2] == sys.argv[1] and argv[3:] == ["--log", sys.argv[2]], argv
assert list(d) == ["hooks"], d
PY
}
out=$(run "" BRIEFING_BACKEND=cli BRIEFING_CLAUDE_CONFIG_DIR=/x/.claude-team)
s=$(settings_of "$T/claude-argv"); [ -n "$s" ] && check_settings "cli path" "$s" || bad "cli path: no --settings on claude's argv: $(tr '\n' ' ' < "$T/claude-argv")"
grep -qx -- '-p' "$T/claude-argv" && grep -q 'mcp__mcp-portal__portal_codemode_execute' "$T/claude-argv" && ok "cli path: still -p with the same allowed tools" || bad "cli argv changed: $(cat "$T/claude-argv")"
BEFORE=1800000000   # a fixed clock; with no refusal on the credit record (its own XDG_STATE_HOME) the SDK runs at any time
out=$(run "" BRIEFING_NOW="$BEFORE")
case "$out" in *"deliver=0"*) ;; *) bad "sdk path run: $out" ;; esac
[ -e "$T/sdk-argv" ] && [ ! -e "$T/claude-argv" ] || bad "sdk path: the runner did not run alone"
s=$(settings_of "$T/sdk-argv"); [ -n "$s" ] && check_settings "sdk path" "$s" || bad "sdk path: no --settings on the runner's argv: $(tr '\n' ' ' < "$T/sdk-argv")"
grep -q -- '--settings' "$D/sdk_run.py" && grep -q 'settings=a.settings or None' "$D/sdk_run.py" && ok "sdk_run.py hands --settings to ClaudeAgentOptions(settings=...), the CLI's --settings" || bad "sdk_run.py: no settings pass-through"
# a plain claude run (release-watch's relay, the shape of any other claude -p) carries no hook
rm -f "$T/claude-argv"
RELEASE_WATCH_STATE="$T/state" RELEASE_WATCH_RELAY_CWD="$T/home" RELEASE_WATCH_CLAUDE_BIN="$T/bin/claude" FAKE_DIR="$T" FAKE_STREAM= BRIEFING_BACKEND=cli \
    sh "$D/release-watch.sh" relay some-session "a message" >/dev/null 2>&1
[ -e "$T/claude-argv" ] && [ -z "$(settings_of "$T/claude-argv")" ] && ok "a non-briefing claude -p (release-watch's relay) gets no --settings and no hook" || bad "relay argv: $(cat "$T/claude-argv" 2>/dev/null)"

# the stream log: a refused call (its tool_result carries the guard's mark) is no Gmail read, no write, and is named
tu() { # tu <id> <tool> <code>: one assistant tool_use line
    python3 -c 'import json,sys; print(json.dumps({"type":"assistant","message":{"content":[{"type":"tool_use","id":sys.argv[1],"name":sys.argv[2],"input":{"code":sys.argv[3]}}]}},separators=(",",":")))' "$1" "$2" "$3"
}
tr_() { # tr_ <id> <text> [is_error]: one user tool_result line
    python3 -c 'import json,sys; print(json.dumps({"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":sys.argv[1],"content":sys.argv[2],"is_error":len(sys.argv)>3}]}},separators=(",",":")))' "$@"
}
DENIED='PreToolUse hook denied this tool call: [briefing-guard] This run may only READ Gmail through the portal. Refused: codemode.gdemo_send_gmail_message: not one of the five Gmail reads.'
{ tu t1 "$EX" 'async () => await codemode.gdemo_search_gmail_messages({ query: "is:unread" })'; tr_ t1 'Retrieved 2 messages'
  tu t2 "$EX" 'async () => await codemode.gdemo_send_gmail_message({ to: "x" })'; tr_ t2 "$DENIED" err
} > "$T/refused.jsonl"
out=$(run "$T/refused.jsonl" BRIEFING_BACKEND=cli)
case "$out" in *"calls=1 writes= refused=gdemo_send_gmail_message"*"deliver=0"*) ok "a refused send: not a write, the one read counted, named as refused, the digest delivered" ;; *) bad "refused send: $out" ;; esac
grep -q '• a line' "$T/posts" && grep -q '⛔ the read guard refused a portal call that was not a Gmail read, before it ran: gdemo_send_gmail_message' "$T/posts" \
    && ok "the digest posts with the refusal under it" || bad "refused footer: $(cat "$T/posts")"
grep -q 'job: the read guard refused portal call(s) before they ran: gdemo_send_gmail_message' "$T/logs/cron.log" && ok "cron.log names the refusal" || bad "cron.log: $(cat "$T/logs/cron.log" 2>/dev/null)"
{ tu t1 "$EX" 'async () => [await codemode.gdemo_get_gmail_thread_content({ thread_id: "a" }), await codemode.gdemo_send_gmail_message({})]'; tr_ t1 "$DENIED" err
} > "$T/mixed.jsonl"
out=$(run "$T/mixed.jsonl" BRIEFING_BACKEND=cli)
case "$out" in *"calls=0 writes= refused=gdemo_send_gmail_message"*"deliver=1"*) ok "a refused mixed read+write: the read did not run either, so the digest is held back as unread" ;; *) bad "refused mixed: $out" ;; esac
grep -q 'held back' "$T/posts" && ! grep -q 'a line' "$T/posts" && ok "… and the held-back notice posts, not the digest" || bad "mixed posts: $(cat "$T/posts")"
{ tu t1 "$EX" 'async () => await codemode.gdemo_search_gmail_messages({ query: "q" })'; tr_ t1 'Retrieved 1 message'
  tu t2 "$EX" 'async () => await codemode[k]({})'; tr_ t2 "[briefing-guard] This run may only READ Gmail. Refused: \`codemode\` used other than as codemode.<gmail read>(...)." err
  tu t3 mcp__claude_ai_Google_Workspace_demo__send_gmail_message ''; tr_ t3 "[briefing-guard] Refused: a Workspace tool that can write (send)." err
} > "$T/noname.jsonl"
out=$(run "$T/noname.jsonl" BRIEFING_BACKEND=cli)
case "$out" in *"refused=portal_codemode_execute send_gmail_message"*"deliver=0"*) ok "a refused call with no gdemo_ name is listed as portal_codemode_execute; a refused direct tool by its short name" ;; *) bad "noname: $out" ;; esac
{ tu t1 "$EX" 'async () => await codemode.gdemo_search_gmail_messages({ query: "q" })'; tr_ t1 'Retrieved 1 message'
  tu t2 "$EX" 'async () => await codemode.gdemo_send_gmail_message({ to: "x" })'; tr_ t2 'Sent.'
} > "$T/ran.jsonl"
out=$(run "$T/ran.jsonl" BRIEFING_BACKEND=cli)
case "$out" in *"calls=1 writes=gdemo_send_gmail_message refused="*"deliver=1"*) ok "a send that RAN (no guard mark) is still a write: held back with the alert (the second line stays)" ;; *) bad "ran: $out" ;; esac
grep -q 'can write: gdemo_send_gmail_message\.' "$T/posts" && ok "… the alert names it" || bad "ran posts: $(cat "$T/posts")"

# the load check: portal calls with no new guard.log line mean the hook never loaded: held back
{ tu t1 "$EX" 'async () => await codemode.gdemo_search_gmail_messages({ query: "is:unread" })'; tr_ t1 'Retrieved 2 messages'
} > "$T/read.jsonl"
out=$(run "$T/read.jsonl" BRIEFING_BACKEND=cli FAKE_HOOK=)
case "$out" in *"calls=1 "*"execs=1 gained=0"*"deliver=1"*) ;; *) bad "guard not loaded: $out" ;; esac
grep -q '🚨 \*Morning Email Summary held back: the read guard did not load\*' "$T/posts" && grep -q "the job run made 1 portal call(s), but $T/logs/guard.log gained no line" "$T/posts" \
    && grep -q "Details: $T/logs/job\.[0-9]*\.jsonl on host-a" "$T/posts" && ! grep -q 'a line' "$T/posts" \
    && ok "portal calls, no new guard.log line: held back with the alert naming the run and its log, the digest not posted" || bad "not loaded posts: $out / $(cat "$T/posts")"
out=$(run "$T/read.jsonl" BRIEFING_BACKEND=cli)
case "$out" in *"execs=1 gained=1"*"deliver=0"*) grep -q '• a line' "$T/posts" && ok "portal calls and the hook's guard.log line (the real hook, run from --settings): posted" || bad "loaded posts: $(cat "$T/posts")" ;; *) bad "guard loaded: $out" ;; esac
{ tu t1 mcp__claude_ai_Google_Workspace_demo__search_gmail_messages ''; tr_ t1 'Retrieved 2 messages'
} > "$T/direct.jsonl"
out=$(run "$T/direct.jsonl" BRIEFING_BACKEND=cli FAKE_HOOK=)
case "$out" in *"calls=1 "*"execs=0 gained=0"*"deliver=0"*) grep -q '• a line' "$T/posts" && ok "no portal call (the direct connector), no guard.log line: posted, the check does not apply" || bad "direct posts: $(cat "$T/posts")" ;; *) bad "direct: $out" ;; esac
# the count runs from before the first attempt: the failed SDK run's hook line counts for the claude -p rerun (a rerun
# that took its own count would hold back a digest whose one portal call went through the hook), and its calls count too
out=$(run "$T/direct.jsonl" BRIEFING_NOW="$BEFORE" FAKE_SDK_FAIL=1 FAKE_HOOK=sdk)
case "$out" in *"calls=1 "*"execs=1 gained=1"*"deliver=0"*) grep -q '• a line' "$T/posts" && grep -q 'job: Agent SDK run failed' "$T/logs/cron.log" \
    && ok "SDK fallback: the failed SDK run's portal call and its guard line both count, from before the SDK attempt: posted" || bad "fallback posts: $(cat "$T/posts")" ;; *) bad "fallback: $out" ;; esac
out=$(run "$T/direct.jsonl" BRIEFING_NOW="$BEFORE" FAKE_SDK_FAIL=1 FAKE_HOOK=)
case "$out" in *"execs=1 gained=0"*"deliver=1"*) grep -q 'held back: the read guard did not load' "$T/posts" \
    && ok "… and with no hook in the SDK run, its portal call (its log moved aside) still holds the rerun's digest back" || bad "fallback unloaded posts: $(cat "$T/posts")" ;; *) bad "fallback unloaded: $out" ;; esac
cp "$T/bin/claude" "$T/bin/claude.keep"
cat > "$T/bin/claude" <<'FAKE'
#!/usr/bin/env bash
# run_claude_retry's two runs: first a portal read through the hook and the connector's OAuth error, then one direct read
if [ ! -e "$FAKE_DIR/first-done" ]; then : > "$FAKE_DIR/first-done"; cat "$FAKE_DIR/read.jsonl"; python3 "$FAKE_DIR/bin/runhook.py" "$FAKE_DIR/read.jsonl" "$@"
    printf '%s\n' '{"type":"result","result":"Google Workspace demo connector needs re-authorization."}'
else cat "$FAKE_DIR/direct.jsonl"; printf '%s\n' '{"type":"result","result":"*digest*\n• a line"}'; fi
FAKE
rm -f "$T/first-done"
out=$(run "" BRIEFING_BACKEND=cli RUN=run_claude_retry)
case "$out" in *"execs=1 gained=1"*"deliver=0"*) grep -q '• a line' "$T/posts" && grep -q 'job: auth sentinel, retrying' "$T/logs/cron.log" \
    && ok "run_claude_retry: the count runs from before the first run, whose hook line covers its portal call: posted" || bad "retry posts: $(cat "$T/posts")" ;; *) bad "retry: $out" ;; esac
cp "$T/bin/claude.keep" "$T/bin/claude"

# BRIEFING_NO_POST (the switch the guard's real test run used): the real post_slack writes the text to would-post.log
# and never opens the webhook (a dead local port here: a missed switch fails fast, not at Slack)
printf 'http://127.0.0.1:9/never\n' > "$T/webhook"
out=$(HOME="$T/home" BRIEFING_LOGDIR="$T/logs" BRIEFING_NO_POST=1 BRIEFING_SESSIONS_CMD=true BRIEFING_BOARD_DIR= BRIEFING_COMMIT_REPOS= \
      bash -c '. "$1/lib.sh" 2>/dev/null; WEBHOOK_FILE=$2/webhook; post_slack "*would post*"; echo "rc=$?"' _ "$D" "$T" 2>&1)
case "$out" in "not posted (BRIEFING_NO_POST)"*"rc=0"*) ok "BRIEFING_NO_POST=1: post_slack posts nothing and says so" ;; *) bad "no-post: $out" ;; esac
grep -q '^\*would post\*$' "$T/logs/would-post.log" 2>/dev/null && ok "… the text lands in would-post.log" || bad "would-post.log: $(cat "$T/logs/would-post.log" 2>/dev/null)"
# briefing_box: the name the posts give this machine. SALA_HEARTBEAT_NAME from the environment, else its line in the sala config, else the hostname
box() { env -u SALA_HEARTBEAT_NAME -u BRIEFING_BOX HOME="$T/home" "$@" bash -c '. "$1/lib.sh" 2>/dev/null; briefing_box' _ "$D"; }
printf 'SALA_HEARTBEAT_NAME=box1   # the fleet name\n' > "$T/box-config"
got=$(box SALA_HEARTBEAT_NAME=host-b SALA_CONFIG="$T/box-config"); [ "$got" = host-b ] && ok "briefing_box: SALA_HEARTBEAT_NAME from the environment wins" || bad "box env: $got"
got=$(box SALA_CONFIG="$T/box-config"); [ "$got" = box1 ] && ok "briefing_box: else the SALA_HEARTBEAT_NAME line of the sala config" || bad "box config: $got"
got=$(box SALA_CONFIG="$T/no-config"); [ -n "$got" ] && [ "$got" = "$(hostname 2>/dev/null || uname -n)" ] && ok "briefing_box: unset everywhere, the hostname (no error)" || bad "box unset: $got"
# the CLAUDE.md echo of the box ("On <box> (…") is dropped from the result, any other line kept
res=$(env -u BRIEFING_BOX HOME="$T/home" BRIEFING_LOGDIR="$T/logs" SALA_HEARTBEAT_NAME=host-a SALA_CONFIG="$T/no-config" FAKE_DIR="$T" FAKE_STREAM= \
      FAKE_RESULT='{"type":"result","result":"On host-a (the fleet coordinator).\n• kept\nOn host-b (other)."}' \
      bash -c '. "$1/lib.sh" 2>/dev/null; CLAUDE_BIN=$2/bin/claude; sleep() { :; }; BRIEFING_BACKEND=cli run_claude job "p" >/dev/null 2>&1; printf "%s" "$RESULT"' _ "$D" "$T")
[ "$res" = "$(printf '• kept\nOn host-b (other).')" ] && ok "run_claude drops the result's \"On <SALA_HEARTBEAT_NAME> (\" line, keeps the rest" || bad "echo drop: $res"
exit $fail
