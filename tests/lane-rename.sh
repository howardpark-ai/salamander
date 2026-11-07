#!/usr/bin/env bash
# The lane rename (the name awsplatform read badly): the lane awsplatform is
# aws-platform now, and the old name stays a WORD for it so nothing that was written or typed before the rename strands. What is checked:
#  1. THE NAMES. lane_norm (awsplatform → aws-platform, every other word as it came), lane_known / lane_canonical / lane_state_id taking both
#     spellings, aws_platform (an underscore) no lane at all.
#  2. HYPHEN SAFETY, spot by spot. A hyphen is legal in a case pattern, an awk field, a JSON value, a file name and a CSS class; it is NOT in a
#     shell variable name: SALA_LANE_<ID>_<FIELD> is made by lane_varid, which drops it, so the lane's config names stay SALA_LANE_AWSPLATFORM_*
#     (an operator's config keeps working) and `${!name}` never sees an invalid name; the same name in the problem line a bad override prints;
#     the case arms of lane_check / lane_env_names / lane_unset_names / lane_env_prefix / lane_args / lane_rc / lane_field; the awk reads of
#     lanes.tsv / lane-state.tsv; `sala lane --json`; the launch line's `env -u …` words; the profile name lane_plain_word still takes a hyphen in.
#  3. THE RECORDS written before. lanes.tsv, lane-default and lane-state.tsv saying awsplatform read as aws-platform (lane_row, lane_default,
#     lane_for_session, lane_dormant, lane_sessions_on) and change nothing by being read; the next write rewrites the old word in the row it
#     writes AND in the rows it carries along (lane_write, lane_drop, lane_rename, lane_set_default, the dormant record's writers); a write of
#     the old word records the new one; lanes.log gets no "set" line for a row that only changes spelling.
#  4. WHAT IS TYPED. `sala lane awsplatform …` (a switch, default, dormant, active) accepted, saying once on stderr that it is the old name, and
#     recording aws-platform; an unknown word lists aws-platform among the lanes; `sala op --plan lane default awsplatform` and
#     `sala spawn --lane awsplatform` the same; `sala lane --json` has no awsplatform id.
#  5. proc_lane printing aws-platform for CLAUDE_CODE_USE_ANTHROPIC_AWS=1 (bedrock first, as before); lane_out reading a limit-watch stop that
#     was recorded under the old word.
#  6. THE MIGRATION, `sala lane --migrate`: --dry-run changes nothing; the real run rewrites lanes.tsv, lane-default, lane-state.tsv and the
#     session registry, keeps a byte-identical backup of each file it changed, adds one `migrate` line to lanes.log and leaves the old lines
#     of it alone; a second run finds nothing, writes nothing and makes no second backup; other rows and the file's mode are kept; the
#     registry's published file and list carry the new name even before it, and `sessions check` treats an old word in a row as drift.
# No tmux server is started (the private socket never exists), no pane is touched, the live state is never read: isolated HOME.
# The end-to-end relaunch from an old row and from the typed old word is in tests/aws-platform-lane.sh. Usage: bash tests/lane-rename.sh (exit 0 = pass; ~20 s)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_SET SALA_SET_SELF SALA_POST_RECYCLE_CMD SALA_RECYCLE SALA_RETRY_WORKER SALA_NO_RELAUNCH SALA_MASTER
unset ANTHROPIC_API_KEY ANTHROPIC_CUSTOM_HEADERS CLAUDE_CONFIG_DIR SALA_LANE_API_KEY_FILE SALA_LANE_API_WORKSPACE_FILE SALA_LANE_API_MCP_CONFIG SALA_LANE_TEAM_DIR
unset AWS_PROFILE AWS_REGION CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_FOUNDRY CLAUDE_CODE_USE_ANTHROPIC_AWS ANTHROPIC_AWS_WORKSPACE_ID ANTHROPIC_AWS_API_KEY
for v in $(compgen -v | grep -E '^SALA_LANE_(MAX|TEAM|API|BEDROCK|AWSPLATFORM)_'); do unset "$v"; done
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"   # short timings, ok/bad/waitfor
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC
as_op_unit   # the guarded verbs this suite runs (lane default) stand for the queue's runner
mkdir -p "$HOME/.claude" "$HOME/.local/bin" "$HOME/.aws"
printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/claude"; chmod +x "$HOME/.local/bin/claude"
export PATH="$HOME/.local/bin:$PATH"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off
SALA="$ROOT/bin/salamander"; SOCK="sala-lanerename-$$"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCK"   # never started: the table finds no panes
cleanup() { kill $PIDS 2>/dev/null; rm -rf "$HOME" 2>/dev/null; true; }; PIDS=""; trap cleanup EXIT
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux    # literal socket: nothing here reaches the fleet's server
# a lane that can launch, so the typed forms reach their dry runs: a workspace id, the profile's header in a credentials file, a claude on PATH
export SALA_LANE_AWSPLATFORM_WORKSPACE_ID=wrkspc_01EXAMPLE SALA_LANE_AWSPLATFORM_CREDENTIALS_FILE="$HOME/.aws/credentials"
printf '[example-bedrock]\naws_access_key_id = DUMMYNOTREAL\n' > "$HOME/.aws/credentials"
. "$ROOT/lib/common.sh"
snapf() { local _f _o=""; for _f in "$@"; do _o="$_o|$(slurp "$_f")"; done; printf "%s" "$_o"; }   # the text of each file, to compare before and after (the shell reads, no md5sum process)
STATE="$SALA_STATE_DIR"; mkdir -p "$STATE"
OLD=awsplatform; NEW=aws-platform

echo "== 1. the names"
[ "$(lane_norm $OLD)" = $NEW ] && [ "$(lane_norm $NEW)" = $NEW ] && [ "$(lane_norm max)" = subscription-1 ] && [ "$(lane_norm team)" = subscription-2 ] && [ "$(lane_norm bedrock)" = bedrock ] && [ "$(lane_norm sdk)" = sdk ] && [ -z "$(lane_norm "")" ] \
    && ok "lane_norm: awsplatform → aws-platform, max → subscription-1, team → subscription-2, every other word (and nothing) as it came" || bad "lane_norm: $(lane_norm $OLD) / $(lane_norm max)"
lane_known $OLD && lane_known $NEW && ok "lane_known takes both spellings" || bad "lane_known"
lane_known aws_platform && bad "aws_platform is no lane" || ok "aws_platform (an underscore) is no lane"
lane_known AWSPLATFORM && bad "AWSPLATFORM is no lane" || ok "AWSPLATFORM (capitals) is no lane"
[ "$(lane_canonical $OLD)" = $NEW ] && [ "$(lane_canonical sdk)" = api ] && [ "$(lane_state_id $OLD)" = $NEW ] && [ "$(lane_state_id sdk)" = api ] && ok "lane_canonical and lane_state_id: awsplatform → aws-platform, sdk → api still" || bad "canonical/state_id"
case " $SALA_LANES_KNOWN " in *" $NEW "*) ok "the lane's name in the list is aws-platform";; *) bad "SALA_LANES_KNOWN: $SALA_LANES_KNOWN";; esac
case " $SALA_LANES_KNOWN $SALA_LANES_DEFINED " in *" $OLD "*) bad "the old word is still in a lane list";; *) ok "the old word is in no lane list (it is a word, not a lane)";; esac
[ "$(lane_field $OLD id)" = $NEW ] && [ "$(lane_field $OLD label)" = "Claude Platform on AWS" ] && ok "lane_field takes the old word and answers for the lane (id aws-platform)" || bad "lane_field old: $(lane_field $OLD id)"

echo "== 2. hyphen safety"
[ "$(lane_varid $NEW)" = AWSPLATFORM ] && [ "$(lane_varid subscription-1)" = SUBSCRIPTION1 ] && [ "$(lane_varid $OLD)" = AWSPLATFORM ] && ok "lane_varid: aws-platform → AWSPLATFORM (no hyphen in a variable name), subscription-1 → SUBSCRIPTION1" || bad "lane_varid: $(lane_varid $NEW)"
[ "$(SALA_LANE_AWSPLATFORM_REGION=us-east-1 lane_field $NEW region)" = us-east-1 ] && [ "$(SALA_LANE_AWSPLATFORM_REGION=us-east-1 lane_field $OLD region)" = us-east-1 ] \
    && ok "the config override SALA_LANE_AWSPLATFORM_REGION still wins (the variable name is unchanged), by either spelling" || bad "region override"
out=$(lane_field $NEW project 2>&1); rc=$?; [ "$rc" = 0 ] && [ "$out" = "$SALA_LANE_AWSPLATFORM_WORKSPACE_ID" ] && ok "the project field is the workspace id (SALA_LANE_AWSPLATFORM_WORKSPACE_ID, read from inside the case arm aws-platform:project)" || bad "project: '$out' ($rc)"
out=$(SALA_LANE_AWSPLATFORM_STATUS=broken lane_fields_problems $NEW); grep -q "(SALA_LANE_AWSPLATFORM_STATUS)" <<< "$out" && ok "the problem line names the real variable (SALA_LANE_AWSPLATFORM_STATUS), not a hyphenated one" || bad "problem line: $out"
[ "$(SALA_LANE_AWSPLATFORM_STATUS=inactive lane_field $NEW status)" = inactive ] && ok "SALA_LANE_AWSPLATFORM_STATUS overrides the derived status" || bad "status override"
[ "$(lane_field $NEW status)" = active ] && ok "the derived status is active when lane_check passes (case arm aws-platform:status)" || bad "derived status: $(lane_field $NEW status) / $(lane_check $NEW)"
lane_check $NEW >/dev/null 2>&1 && lane_check $OLD >/dev/null 2>&1 && ok "lane_check passes for both spellings (the arm is aws-platform)" || bad "lane_check: $(lane_check $NEW)"
out=$(SALA_LANE_AWSPLATFORM_WORKSPACE_ID= lane_check $OLD 2>&1); grep -q '^aws-platform lane: no workspace id yet' <<< "$out" && ok "its refusals say aws-platform" || bad "refusal text: $out"
out=$(lane_check bogus 2>&1); grep -q '(one of: subscription-1 api subscription-2 sdk bedrock aws-platform)' <<< "$out" && ok "an unknown word lists the lanes, aws-platform among them" || bad "unknown: $out"
[ "$(lane_env_names $NEW)" = "$(lane_env_names $OLD)" ] && [ -n "$(lane_env_names $NEW)" ] && grep -q CLAUDE_CODE_USE_ANTHROPIC_AWS <<< "$(lane_env_names $NEW)" && ok "lane_env_names: the same for both spellings, with CLAUDE_CODE_USE_ANTHROPIC_AWS" || bad "env names"
[ "$(lane_unset_names $NEW)" = "$(lane_unset_names $OLD)" ] && [ "$(lane_unset_names $NEW)" = "CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_FOUNDRY ANTHROPIC_AWS_API_KEY" ] && ok "lane_unset_names: the three variables, by either spelling" || bad "unset names: $(lane_unset_names $NEW)"
pre_new=$(lane_env_prefix $NEW); pre_old=$(lane_env_prefix $OLD)
[ "$pre_new" = "$pre_old" ] && case "$pre_new" in "env -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_FOUNDRY -u ANTHROPIC_AWS_API_KEY AWS_PROFILE=example-bedrock CLAUDE_CODE_USE_ANTHROPIC_AWS=1 ANTHROPIC_AWS_WORKSPACE_ID=wrkspc_01EXAMPLE AWS_REGION=us-east-1 "*) true;; *) false;; esac \
    && ok "lane_env_prefix: the launch line is the lane's (env -u first, the profile 'example-bedrock' with its hyphens, the flag CLAUDE_CODE_USE_ANTHROPIC_AWS=1 untouched), the same for both spellings" || bad "env prefix: $pre_new"
lane_rc $NEW && bad "aws-platform has Remote Control" || { lane_rc $OLD && bad "the old spelling has Remote Control" || ok "lane_rc: no Remote Control on either spelling"; }
[ -z "$(SALA_LANE_API_MCP_CONFIG=$HOME/m.json lane_args $NEW)" ] && : > "$HOME/m.json" && [ "$(SALA_LANE_API_MCP_CONFIG=$HOME/m.json lane_args $NEW)" = "$(SALA_LANE_API_MCP_CONFIG=$HOME/m.json lane_args $OLD)" ] && ok "lane_args: --mcp-config only with the file, the same for both spellings" || bad "lane_args"
lane_plain_word example-bedrock && ! lane_plain_word 'a b' && ok "lane_plain_word still takes a hyphenated profile name (a hyphen was never the problem there)" || bad "lane_plain_word"
out=$(lane_fields_tsv | awk -F'\t' '$1 == "aws-platform" { n = NF; print $1 "|" n }'); [ "$out" = "aws-platform|13" ] && ok "lane_fields_tsv: the row's first field is aws-platform, thirteen tab-separated fields (an awk field with a hyphen)" || bad "tsv row: $out"
out=$("$SALA" lane --json 2>&1); python3 -I - "$out" <<'PY' && ok "lane --json: the id is aws-platform (JSON value), no awsplatform anywhere" || bad "lane --json"
import json, sys
d = json.loads(sys.argv[1])
ids = [r["id"] for r in d["lanes"]]
assert ids == ["subscription-1", "subscription-2", "api", "bedrock", "aws-platform"], ids
assert "awsplatform" not in sys.argv[1]
PY
out=$("$SALA" lane --list 2>&1); grep -q '^aws-platform  *Claude Platform on AWS' <<< "$out" && ! grep -q awsplatform <<< "$out" && ok "lane --list: the row starts aws-platform" || bad "lane --list: $out"

echo "== 3. records written before the rename"
printf 'a\t%s\nb\tmax\nc\t%s\nd\tbedrock\n' $OLD $OLD > "$SALA_LANES"; echo $OLD > "$SALA_LANE_DEFAULT_FILE"
printf '%s\tdormant\tno workspace\t2026-01-05T00:00:00Z\t\thand\nteam\tdormant\tseat gone\t2026-01-06T00:00:00Z\t\tsignal\n' $OLD > "$SALA_LANE_STATE"
sums0=$(snapf "$SALA_LANES" "$SALA_LANE_DEFAULT_FILE" "$SALA_LANE_STATE")
[ "$(lane_row a)" = $NEW ] && [ "$(lane_row b)" = subscription-1 ] && [ "$(lane_row zz)" = "" ] && ok "lane_row: an old row reads as aws-platform, a max row as subscription-1, others as they are" || bad "lane_row: $(lane_row a)"
[ "$(lane_default)" = $NEW ] && ok "lane_default: an old lane-default reads as aws-platform" || bad "lane_default: $(lane_default)"
[ "$(lane_for_session a)" = $NEW ] && [ "$(lane_for_session zz)" = $NEW ] && ok "lane_for_session: the old row, and a session with none (the old default), launch on aws-platform" || bad "for_session: $(lane_for_session a) $(lane_for_session zz)"
lane_dormant $NEW && lane_dormant $OLD && ok "lane_dormant: a record keyed by the old word is the lane's" || bad "lane_dormant"
[ "$(lane_state_field $NEW 3)" = "no workspace" ] && ok "lane_state_field reads its reason" || bad "state field: $(lane_state_field $NEW 3)"
lane_dormant team && lane_dormant subscription-2 && ok "and a row keyed team is subscription-2's, asked by either word" || bad "team dormant"
[ "$(lane_sessions_on $NEW | tr '\n' ' ')" = "a c " ] && ok "lane_sessions_on aws-platform: the two old rows" || bad "sessions_on: '$(lane_sessions_on $NEW | tr '\n' ' ')'"
out=$("$SALA" lane 2>&1); grep -qE "^a +aws-platform " <<< "$out" && ! grep -q "is not a lane" <<< "$out" && ok "the table shows an old row as aws-platform and does not flag it" || bad "table: $out"
[ "$(snapf "$SALA_LANES" "$SALA_LANE_DEFAULT_FILE" "$SALA_LANE_STATE")" = "$sums0" ] && ok "none of those reads rewrote a file" || bad "a read rewrote a file"
out=$(lane_out $NEW 2>&1); grep -q 'dormant' <<< "$out" && ok "lane_out sees the old dormant row" || bad "lane_out: $out"
# the next write rewrites: lane_write of another session carries every old row along
printf 'a\t%s\nb\tsubscription-1\nc\t%s\nd\tbedrock\n' $OLD $OLD > "$SALA_LANES"
lane_write b subscription-1 || bad "lane_write failed"; [ "$(grep -c "^a	$OLD$" "$SALA_LANES")" = 1 ] && ok "a write that changes nothing (b's row already says subscription-1) writes nothing: the old rows stay until the next real write" || bad "a no-op write rewrote the table"
lane_write b subscription-2 || bad "lane_write failed"
if grep -q "^a	$OLD$" "$SALA_LANES"; then bad "a write left an old row in lanes.tsv: $(<"$SALA_LANES")"; else ok "a write (lane_write b subscription-2) rewrote the old rows it carried along"; fi
grep -qP "^a\t$NEW$" "$SALA_LANES" && grep -qP "^c\t$NEW$" "$SALA_LANES" && grep -qP '^d\tbedrock$' "$SALA_LANES" && ok "the rows now say aws-platform; bedrock as it was" || bad "rows: $(<"$SALA_LANES")"
lane_write a $OLD && ok "lane_write a awsplatform: accepted" || bad "lane_write old word"
[ "$(wc -l < "$SALA_LANES")" = 4 ] && ok "four rows, no duplicate" || bad "rows: $(<"$SALA_LANES")"
printf 'e\t%s\n' $OLD >> "$SALA_LANES"
lane_write e $NEW; grep -qP "^e\t$NEW$" "$SALA_LANES" && ok "lane_write on a session whose row has the old word writes the new one (it is not 'already')" || bad "lane_write e: $(<"$SALA_LANES")"
! grep -qP "\tset\te\t$OLD" "$SALA_LANE_LOG" && ok "and logs no 'set' line for a change of spelling alone" || bad "a spelling-only change was logged: $(tail -2 "$SALA_LANE_LOG")"
printf 'f\t%s\n' $OLD >> "$SALA_LANES"; lane_rename f g; grep -qP "^g\t$NEW$" "$SALA_LANES" && ! grep -q "^f	" "$SALA_LANES" && ok "lane_rename carries an old row as aws-platform" || bad "rename: $(<"$SALA_LANES")"
printf 'h\t%s\nb\tmax\n' $OLD >> "$SALA_LANES"; lane_drop b; ! grep -q awsplatform "$SALA_LANES" && ok "lane_drop rewrites the old rows it carries" || bad "drop: $(<"$SALA_LANES")"
echo $OLD > "$SALA_LANE_DEFAULT_FILE"
lane_set_default $NEW; [ "$(<"$SALA_LANE_DEFAULT_FILE")" = $NEW ] && ok "lane_set_default aws-platform over an old lane-default rewrites it (not 'already')" || bad "default file: $(<"$SALA_LANE_DEFAULT_FILE")"
lane_set_default subscription-1; lane_set_default $OLD; [ "$(<"$SALA_LANE_DEFAULT_FILE")" = $NEW ] && ok "lane_set_default awsplatform records aws-platform" || bad "default file after old word: $(<"$SALA_LANE_DEFAULT_FILE")"
lane_set_default subscription-1
printf '%s\tdormant\tno workspace\t2026-01-05T00:00:00Z\t\thand\nteam\tdormant\tseat gone\t2026-01-06T00:00:00Z\t\tsignal\n' $OLD > "$SALA_LANE_STATE"
lane_dormant_clear $OLD "test"; ! lane_dormant $NEW && grep -qP '^aws-platform\tactive' "$SALA_LANE_STATE" && ! grep -q "^$OLD	" "$SALA_LANE_STATE" && lane_dormant subscription-2 && ok "lane_dormant_clear on the old-keyed row: one aws-platform row, active; the team row still dormant" || bad "state: $(<"$SALA_LANE_STATE")"
lane_dormant_set $OLD "again" hand >/dev/null; [ "$(grep -c '' "$SALA_LANE_STATE")" = 2 ] && lane_dormant $NEW && ok "lane_dormant_set by the old word: still two rows (no old+new pair)" || bad "state: $(<"$SALA_LANE_STATE")"

echo "== 4. what is typed"
rm -f "$SALA_LANES" "$SALA_LANE_STATE" "$SALA_LANE_DEFAULT_FILE"
out=$("$SALA" lane default $OLD --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q 'would set the default lane: aws-platform' <<< "$out" && grep -q "awsplatform is the old name of the aws-platform lane" <<< "$out" && ok "lane default awsplatform --dry-run: accepted, aws-platform, said once to be the old name" || bad "default dry-run ($rc): $out"
out=$("$SALA" lane default $NEW --dry-run 2>&1); ! grep -q 'old name' <<< "$out" && ok "the new name says nothing about an old one" || bad "new name noise: $out"
out=$("$SALA" lane dormant $OLD --reason test --dry-run 2>&1); grep -q 'would mark the Claude Platform on AWS lane dormant' <<< "$out" && ok "lane dormant awsplatform --dry-run: the Claude Platform on AWS lane" || bad "dormant dry-run: $out"
out=$("$SALA" lane dormant $OLD --reason "no workspace" 2>&1); rc=$?
[ "$rc" = 0 ] && grep -qP '^aws-platform\tdormant\tno workspace' "$SALA_LANE_STATE" && ! grep -q awsplatform "$SALA_LANE_STATE" && ok "lane dormant awsplatform records the aws-platform row" || bad "dormant ($rc): $out / $(<"$SALA_LANE_STATE")"
out=$("$SALA" lane $OLD a 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q 'lane is dormant' <<< "$out" && ok "a switch onto the dormant lane by the old word is refused as dormant" || bad "switch refusal ($rc): $out"
"$SALA" lane active $OLD >/dev/null 2>&1; ! lane_dormant $NEW && ok "lane active awsplatform clears it" || bad "lane active"
out=$("$SALA" lane aws_platform a 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q "unknown lane 'aws_platform' (one of: subscription-1 api subscription-2 sdk bedrock aws-platform)" <<< "$out" && ok "aws_platform: unknown lane, the list names aws-platform" || bad "unknown ($rc): $out"
out=$("$SALA" lane $OLD 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q 'which sessions?' <<< "$out" && grep -q 'salamander lane aws-platform <session>' <<< "$out" && ok "a switch with no session: the usage line says aws-platform" || bad "usage ($rc): $out"
out=$("$SALA" op --plan lane default $OLD 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q 'aws-platform' <<< "$out" && ! grep -qE 'default awsplatform' <<< "$out" && ok "sala op --plan lane default awsplatform: planned as aws-platform" || bad "op plan ($rc): $out"
out=$("$SALA" op --plan lane default $NEW 2>&1); [ $? = 0 ] && ok "and by the new name" || bad "op plan new: $out"
out=$("$SALA" op --plan lane default aws_platform 2>&1); rc=$?; [ "$rc" != 0 ] && grep -q "is not a lane (one of: subscription-1 api subscription-2 sdk bedrock aws-platform)" <<< "$out" && ok "op: an unknown word lists aws-platform" || bad "op unknown ($rc): $out"
out=$("$SALA" spawn sala-test-x --lane $OLD --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q 'lane' <<< "$out" && ! grep -q "is not a lane" <<< "$out" && ok "spawn --lane awsplatform --dry-run: accepted" || bad "spawn dry-run ($rc): $out"

echo "== 5. proc_lane and the limit watch's state"
env CLAUDE_CODE_USE_ANTHROPIC_AWS=1 sleep 30 & p1=$!; PIDS="$PIDS $p1"
env CLAUDE_CODE_USE_BEDROCK=1 CLAUDE_CODE_USE_ANTHROPIC_AWS=1 sleep 30 & p2=$!; PIDS="$PIDS $p2"
env CLAUDE_CODE_USE_ANTHROPIC_AWS=0 sleep 30 & p3=$!; PIDS="$PIDS $p3"
for p in $p1 $p2 $p3; do waitfor "tr '\\0' '\\n' < /proc/$p/environ 2>/dev/null | grep -q '^CLAUDE_CODE_USE_ANTHROPIC_AWS='" 20; done   # until each has exec'd sleep with its env
[ "$(proc_lane $p1)" = $NEW ] && ok "proc_lane: CLAUDE_CODE_USE_ANTHROPIC_AWS=1 → aws-platform" || bad "proc_lane: $(proc_lane $p1)"
[ "$(proc_lane $p2)" = bedrock ] && ok "with CLAUDE_CODE_USE_BEDROCK=1 too: bedrock first, as the CLI routes" || bad "proc_lane both: $(proc_lane $p2)"
[ "$(proc_lane $p3)" = subscription-1 ] && ok "CLAUDE_CODE_USE_ANTHROPIC_AWS=0 is no lane variable: subscription-1" || bad "proc_lane 0: $(proc_lane $p3)"
mkdir -p "$(dirname "$SALA_LIMIT_STATE")"
printf '{"panes": {"u1": {"s": "old-pane", "lane": "awsplatform", "lim": "seven_day", "since": 1792000000, "reset": 0}}}' > "$SALA_LIMIT_STATE"
out=$(lane_out $NEW 2>&1); grep -q 'the limit watch has old-pane stopped on it\|the limit watch has 1 pane stopped on it (old-pane)' <<< "$out" && ok "lane_out aws-platform sees a stop recorded under the old word" || bad "lane_out: $out"
out=$(lane_out $OLD 2>&1); grep -q 'old-pane' <<< "$out" && ok "and when asked by the old word" || bad "lane_out old: $out"
rm -f "$SALA_LIMIT_STATE"

echo "== 6. the migration"
printf 'a\t%s\nb\tmax\nc\t%s\n' $OLD $OLD > "$SALA_LANES"; echo $OLD > "$SALA_LANE_DEFAULT_FILE"
printf '%s\tdormant\tno workspace\t2026-01-05T00:00:00Z\t\thand\nteam\tactive\t\t2026-01-06T00:00:00Z\t\tsignal\n' $OLD > "$SALA_LANE_STATE"
chmod 640 "$SALA_LANES"
printf '%s\tset\tzz\t(default) → %s\tx\n' "2026-01-10T00:00:00+00:00" $OLD > "$SALA_LANE_LOG"
cat > "$SALA_SESSIONS_FILE" <<JSON
{"v": 1, "sessions": {"r1": {"id": "r1", "name": "a", "lane": "$OLD", "state": "live", "created": "2026-01-05T00:00:00Z", "aliases": [], "transcripts": [], "project": null, "role": null, "model": null, "effort": null}, "r2": {"id": "r2", "name": "b", "lane": "max", "state": "live", "created": "2026-01-05T00:00:00Z", "aliases": [], "transcripts": [], "project": null, "role": null, "model": null, "effort": null}, "r3": {"id": "r3", "name": "gone", "lane": "$OLD", "state": "retired", "created": "2026-10-19T00:00:00Z", "aliases": [], "transcripts": [], "project": null, "role": null, "model": null, "effort": null}}}
JSON
cp "$SALA_LANES" "$HOME/lanes.orig"; cp "$SALA_LANE_DEFAULT_FILE" "$HOME/default.orig"; cp "$SALA_LANE_STATE" "$HOME/state.orig"; cp "$SALA_LANE_LOG" "$HOME/log.orig"; cp "$SALA_SESSIONS_FILE" "$HOME/reg.orig"
SUMS=$(snapf "$SALA_LANES" "$SALA_LANE_DEFAULT_FILE" "$SALA_LANE_STATE" "$SALA_LANE_LOG" "$SALA_SESSIONS_FILE")
# the registry reads the new name before any migration: the published file and the list
python3 -I - "$ROOT/lib" "$SALA_SESSIONS_FILE" <<'PY' && ok "the registry's published file carries aws-platform for an old row (live and retired), and a stored max as subscription-1" || bad "export_doc"
import sys, json
sys.path.insert(0, sys.argv[1]); import sessions
d = sessions.export_doc(sys.argv[2], "m", "t")
lanes = {r["name"]: r["lane"] for r in d["sessions"].values()}
assert lanes == {"a": "aws-platform", "b": "subscription-1", "gone": "aws-platform"}, lanes   # the stored max reads as subscription-1
PY
out=$("$SALA" lane --migrate --dry-run 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(snapf "$SALA_LANES" "$SALA_LANE_DEFAULT_FILE" "$SALA_LANE_STATE" "$SALA_LANE_LOG" "$SALA_SESSIONS_FILE")" = "$SUMS" ] && [ -z "$(ls "$STATE" | grep -F pre-aws-platform)" ] \
    && grep -q 'would rewrite 2 row(s) of' <<< "$out" && grep -q 'would rewrite 1 row(s) of' <<< "$out" && grep -q '2 row(s) would change' <<< "$out" \
    && ok "--dry-run: says what it would rewrite (2 table rows, the default, 1 state row, 2 registry rows) and changes nothing, makes no backup" || bad "dry-run ($rc): $out"
out=$("$SALA" lane --migrate 2>&1); rc=$?
[ "$rc" = 0 ] && ok "lane --migrate: exit 0" || bad "migrate ($rc): $out"
[ "$(<"$SALA_LANES")" = "$(sed "s/$OLD/$NEW/" "$HOME/lanes.orig")" ] && ok "lanes.tsv: the two old rows rewritten, the max row and the order as they were" || bad "lanes.tsv: $(<"$SALA_LANES")"
[ "$(stat -c %a "$SALA_LANES")" = 640 ] && ok "the file's mode is kept (640)" || bad "mode: $(stat -c %a "$SALA_LANES")"
[ "$(<"$SALA_LANE_DEFAULT_FILE")" = $NEW ] && ok "lane-default: aws-platform" || bad "default: $(<"$SALA_LANE_DEFAULT_FILE")"
[ "$(<"$SALA_LANE_STATE")" = "$(sed "s/^$OLD/$NEW/" "$HOME/state.orig")" ] && ok "lane-state.tsv: the one row rewritten, team's as it was" || bad "state: $(<"$SALA_LANE_STATE")"
python3 -I - "$SALA_SESSIONS_FILE" <<'PY' && ok "the registry's rows: the live and the retired old row say aws-platform, max as it was" || bad "registry rows"
import json, sys
d = json.load(open(sys.argv[1]))["sessions"]
assert {r["name"]: r["lane"] for r in d.values()} == {"a": "aws-platform", "b": "max", "gone": "aws-platform"}, d
PY
n=0; for pair in "lanes.tsv:lanes.orig" "lane-default:default.orig" "lane-state.tsv:state.orig"; do
    f="$STATE/${pair%%:*}"; b=$(ls "$f".pre-aws-platform-* 2>/dev/null | head -1); [ -n "$b" ] && cmp -s "$b" "$HOME/${pair##*:}" && n=$((n+1))
done
[ "$n" = 3 ] && ok "a byte-identical backup of each rewritten file (<file>.pre-aws-platform-<time>)" || bad "backups ($n of 3): $(ls "$STATE")"
[ -n "$(ls "$STATE"/sessions.json.pre-aws-platform-* 2>/dev/null)" ] || ls "$STATE"/sessions-history 2>/dev/null | grep -q . && ok "the registry keeps its own history copy before it writes (sessions-history)" || bad "no registry history"
head -1 "$SALA_LANE_LOG" | cmp -s - <(head -1 "$HOME/log.orig") && tail -1 "$SALA_LANE_LOG" | grep -qP '\tmigrate\t-\tawsplatform → aws-platform: \d+ record\(s\) rewritten' && ok "lanes.log: the old history line untouched, one 'migrate' line added" || bad "lanes.log: $(<"$SALA_LANE_LOG")"
nb=$(ls "$STATE" | grep -c 'pre-aws-platform'); sums1=$(snapf "$SALA_LANES" "$SALA_LANE_DEFAULT_FILE" "$SALA_LANE_STATE")
out=$("$SALA" lane --migrate 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q '^nothing to migrate' <<< "$out" && [ "$(ls "$STATE" | grep -c 'pre-aws-platform')" = "$nb" ] && [ "$(snapf "$SALA_LANES" "$SALA_LANE_DEFAULT_FILE" "$SALA_LANE_STATE")" = "$sums1" ] \
    && [ "$(grep -c 'migrate' "$SALA_LANE_LOG")" = 1 ] && ok "a second run: 'nothing to migrate', no new backup, nothing rewritten, no second log line (idempotent)" || bad "second run ($rc): $out"
out=$("$SALA" lane --migrate --all 2>&1); rc=$?; [ "$rc" = 1 ] && ok "--migrate takes only --dry-run" || bad "--migrate --all ($rc): $out"
out=$("$SALA" lane --migrate sala-test-a 2>&1); rc=$?; [ "$rc" = 1 ] && ok "--migrate with a session: refused" || bad "--migrate a ($rc): $out"
rm -f "$SALA_LANES" "$SALA_LANE_DEFAULT_FILE" "$SALA_LANE_STATE" "$SALA_SESSIONS_FILE"
out=$("$SALA" lane --migrate 2>&1); rc=$?; [ "$rc" = 0 ] && grep -q '^nothing to migrate' <<< "$out" && ok "with no state files at all: nothing to migrate, exit 0" || bad "empty migrate ($rc): $out"
out=$("$SALA" lane --help 2>&1); grep -q 'lane --migrate' <<< "$out" && ok "lane --help lists --migrate" || bad "help: $out"

echo "== 7. the registry: an old word in a row is drift"
printf 'a\t%s\n' $OLD > "$SALA_LANES"
python3 -I - "$ROOT/lib" <<'PY' && ok "sessions.norm_lane and table_fields read the old word as aws-platform (so sessions check sees a registry row that still says it as different from the table, and rewrites it)" || bad "sessions.py helpers"
import sys
sys.path.insert(0, sys.argv[1]); import sessions
assert sessions.norm_lane("awsplatform") == "aws-platform" and sessions.norm_lane("max") == "subscription-1" and sessions.norm_lane("team") == "subscription-2" and sessions.norm_lane("api") == "api" and sessions.migrated_lane("max") == "max" and sessions.migrated_lane("awsplatform") == "aws-platform" and sessions.norm_lane(None) is None
f = sessions.table_fields({"a": ["awsplatform"]}, {}, "a")
assert f["lane"] == "aws-platform", f
PY

[ "$fail" = 0 ] && echo "lane-rename: pass" || echo "lane-rename: FAIL"
exit $fail
