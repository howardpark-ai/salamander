#!/usr/bin/env bash
# The login lanes' new codes: the lane `max` is `subscription-1` and the lane `team` is `subscription-2`, and the
# first one's display name, Ultra, lives in ONE setting (the lane's label field: SALA_LANE_SUBSCRIPTION1_LABEL) that everything sala
# shows reads. The old words stay words for the lanes, as awsplatform did (tests/lane-rename.sh is that rename's guard). What is checked:
#  1. THE NAMES. lane_norm max → subscription-1 and team → subscription-2 (and every other word as it came); lane_known / lane_canonical /
#     lane_state_id / lane_field take both words; the lane lists name the new codes and neither old word; lane_varid gives the hyphen-free
#     variable part (SUBSCRIPTION1) and the config written before (SALA_LANE_MAX_*, SALA_LANE_TEAM_*) still counts.
#  2. THE OLD WORDS ARE READ AS THE NEW CODES wherever a lane word is read: lanes.tsv, lane-default, lane-state.tsv (lane_dormant,
#     lane_state_field), lane-home.tsv, SALA_LANE_FALLBACK, a typed word (`sala lane default team`, `sala op --plan …`, `sala spawn --lane`),
#     the registry (sessions.py norm_lane) and the Python helpers (lanewords.py, unitjob.py's LANES).
#  3. NEW WRITES USE THE NEW CODES: lane_write, lane_set_default and the dormant record's writers record subscription-1 / subscription-2
#     (an old word typed records the new one), and a dormant row written under the old word is replaced, never paired with a new one.
#  4. A READ REWRITES NOTHING: files that say max / team / awsplatform are byte-identical after every reader has run (the table, --list,
#     --json, lane names, lane_row, lane_default, lane_dormant, lane_home …).
#  5. THE DISPLAY NAME: lane_label (bash) and lanewords.lane_label (Python) give Ultra / Team / API / Bedrock / Claude Platform on AWS for
#     the code or the old word; the setting overrides it everywhere at once (SALA_LANE_SUBSCRIPTION1_LABEL, and the old SALA_LANE_MAX_LABEL);
#     lane_shown (the word a post or a summary uses) and the lane usage text read it.
#  6. `sala lane names [--json] [--write]`: the text form (code, display, aliases, tab-separated), the JSON shape stackshot reads
#     (exactly {"lanes":[{"code","display","aliases"}]}, every known lane, aliases [] when none), the override showing in it.
#  7. $SALA_STATE_DIR/lane-names.json: written by --write and by a `sala watch` tick, atomically (no temp file left, a reader never sees a
#     half file), and ONLY when the content differs (inode and mtime stay when nothing changed).
#  8. NO USER-VISIBLE "Max" / "Team lane" FOR OUR LANE in lib/ bin/ web/src outside comments, the lane table's own definitions and the
#     allow-list of Anthropic's plan names (a login's subscriptionType, "Max 20x", the plans).
# No tmux server is started (the private socket never exists), no pane is touched, the live state is never read: isolated HOME, locked.
# Usage: bash tests/lane-subscription-codes.sh   (exit 0 = pass; ~25 s)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_SET SALA_SET_SELF SALA_POST_RECYCLE_CMD SALA_RECYCLE SALA_RETRY_WORKER SALA_NO_RELAUNCH SALA_MASTER
unset ANTHROPIC_API_KEY ANTHROPIC_CUSTOM_HEADERS CLAUDE_CONFIG_DIR SALA_LANE_API_KEY_FILE SALA_LANE_API_WORKSPACE_FILE SALA_LANE_API_MCP_CONFIG SALA_LANE_TEAM_DIR SALA_LANE_FALLBACK SALA_JOB_LANE
unset AWS_PROFILE AWS_REGION CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_FOUNDRY CLAUDE_CODE_USE_ANTHROPIC_AWS ANTHROPIC_AWS_WORKSPACE_ID ANTHROPIC_AWS_API_KEY
for v in $(compgen -v | grep -E '^SALA_LANE_(MAX|TEAM|SUBSCRIPTION1|SUBSCRIPTION2|API|BEDROCK|AWSPLATFORM)_'); do unset "$v"; done
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"   # short timings, ok/bad/waitfor
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC
exec 7< "$HOME"; flock -n 7 || true   # the temp folder is locked while the suite runs (systemd-tmpfiles ageing honours it)
as_op_unit   # the guarded verbs this suite runs (lane default) stand for the queue's runner
mkdir -p "$HOME/.claude" "$HOME/.local/bin"
printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/claude"; chmod +x "$HOME/.local/bin/claude"
export PATH="$HOME/.local/bin:$PATH"
mkdir -p "$HOME/.claude-team"; printf '{"fake":true}\n' > "$HOME/.claude-team/.credentials.json"   # the second login lane has a directory and a login, so a switch onto it passes lane_check
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off
SALA="$ROOT/bin/salamander"; SOCK="sala-lanecodes-$$"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCK"   # never started: the table finds no panes
PIDS=""   # pids of helper processes this suite starts itself (each killed by its pid, never by name)
cleanup() { [ -z "$PIDS" ] || kill $PIDS 2>/dev/null; rm -rf "$HOME" 2>/dev/null; true; }; trap cleanup EXIT
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux    # literal socket: nothing here reaches the fleet's server
. "$ROOT/lib/common.sh"
snapf() { local _f _o=""; for _f in "$@"; do _o="$_o|$(slurp "$_f")"; done; printf "%s" "$_o"; }   # the text of each file, to compare before and after
STATE="$SALA_STATE_DIR"; mkdir -p "$STATE"
S1=subscription-1; S2=subscription-2

echo "== 1. the names"
[ "$(lane_norm max)" = $S1 ] && [ "$(lane_norm team)" = $S2 ] && [ "$(lane_norm $S1)" = $S1 ] && [ "$(lane_norm $S2)" = $S2 ] && [ "$(lane_norm api)" = api ] \
    && [ "$(lane_norm bedrock)" = bedrock ] && [ "$(lane_norm sdk)" = sdk ] && [ "$(lane_norm awsplatform)" = aws-platform ] && [ -z "$(lane_norm "")" ] \
    && ok "lane_norm: max → subscription-1, team → subscription-2, awsplatform → aws-platform, every other word (and nothing) as it came" || bad "lane_norm: $(lane_norm max) / $(lane_norm team)"
lane_known max && lane_known team && lane_known $S1 && lane_known $S2 && ok "lane_known takes the old words and the new codes" || bad "lane_known"
lane_known Max && bad "Max (capital) is no lane" || ok "Max (a capital) is no lane word"
lane_known subscription1 && bad "subscription1 is no lane" || ok "subscription1 (no hyphen) is no lane word"
[ "$(lane_canonical max)" = $S1 ] && [ "$(lane_canonical team)" = $S2 ] && [ "$(lane_state_id max)" = $S1 ] && [ "$(lane_state_id team)" = $S2 ] && [ "$(lane_state_id sdk)" = api ] \
    && ok "lane_canonical and lane_state_id: max → subscription-1, team → subscription-2, sdk → api still" || bad "canonical/state_id"
case " $SALA_LANES_KNOWN $SALA_LANES_DEFINED " in *" max "*|*" team "*) bad "an old word is in a lane list: $SALA_LANES_KNOWN | $SALA_LANES_DEFINED";; *" $S1 "*" $S2 "*) ok "the lane lists name subscription-1 and subscription-2, and neither old word";; *) bad "the lane lists: $SALA_LANES_KNOWN";; esac
[ "$(lane_field max id)" = $S1 ] && [ "$(lane_field team id)" = $S2 ] && [ "$(lane_field $S1 billing)" = subscription ] && [ "$(lane_field team plan)" = "" ] && ok "lane_field takes either word and answers for the lane" || bad "lane_field: $(lane_field max id) $(lane_field team id)"
[ "$(lane_varid $S1)" = SUBSCRIPTION1 ] && [ "$(lane_varid $S2)" = SUBSCRIPTION2 ] && ok "lane_varid: subscription-1 → SUBSCRIPTION1, subscription-2 → SUBSCRIPTION2 (no hyphen in a variable name)" || bad "lane_varid: $(lane_varid $S1)"
( SALA_LANE_MAX_ACCOUNT=old@example.org; SALA_LANE_TEAM_ORG=old-org; [ "$(lane_field $S1 account)" = old@example.org ] && [ "$(lane_field $S2 org)" = old-org ] ) \
    && ok "a config written before (SALA_LANE_MAX_ACCOUNT, SALA_LANE_TEAM_ORG) still counts for the new codes" || bad "the old config names"
( SALA_LANE_SUBSCRIPTION1_ACCOUNT=new@example.org; SALA_LANE_MAX_ACCOUNT=old@example.org; [ "$(lane_field $S1 account)" = new@example.org ] ) \
    && ok "the new variable wins over the old one" || bad "the new config name does not win"
out=$(lane_check bogus 2>&1); grep -q "(one of: $S1 api $S2 sdk bedrock aws-platform)" <<< "$out" && ok "an unknown word lists the lanes by their new codes" || bad "unknown: $out"
out=$("$SALA" lane --json 2>&1); python3 -I - "$out" <<'PY' && ok "lane --json: the ids are the new codes, no max or team id" || bad "lane --json"
import json, sys
d = json.loads(sys.argv[1]); ids = [r["id"] for r in d["lanes"]]
assert ids == ["subscription-1", "subscription-2", "api", "bedrock", "aws-platform"], ids
assert "max" not in ids and "team" not in ids
assert [r["label"] for r in d["lanes"]][:2] == ["Ultra", "Team"], d["lanes"]
PY

echo "== 2. the old words are read as the new codes"
OLDSTAMP="2026-01-05T00:00:00Z"
printf 'a\tmax\nb\tteam\nc\tapi\nd\tawsplatform\n' > "$SALA_LANES"; echo max > "$SALA_LANE_DEFAULT_FILE"
printf 'max\tdormant\tlogin changed\t%s\t\tsignal\nteam\tdormant\tseat gone\t%s\t\thand\n' $OLDSTAMP $OLDSTAMP > "$SALA_LANE_STATE"
printf 'a\tmax\t%s\t-\n' $OLDSTAMP > "$SALA_LANE_HOME"
[ "$(lane_row a)" = $S1 ] && [ "$(lane_row b)" = $S2 ] && [ "$(lane_row c)" = api ] && [ "$(lane_row d)" = aws-platform ] && [ "$(lane_row zz)" = "" ] && ok "lane_row: a max row reads as subscription-1, a team row as subscription-2, the rest as before" || bad "lane_row: $(lane_row a) $(lane_row b)"
[ "$(lane_default)" = $S1 ] && ok "lane_default: a lane-default saying max reads as subscription-1" || bad "lane_default: $(lane_default)"
[ "$(lane_for_session a)" = $S1 ] && [ "$(lane_for_session b)" = $S2 ] && [ "$(lane_for_session zz)" = $S1 ] && ok "lane_for_session: the max and team rows, and a session with none (the max default), launch on the new codes" || bad "for_session: $(lane_for_session a) $(lane_for_session b) $(lane_for_session zz)"
lane_dormant $S1 && lane_dormant max && lane_dormant $S2 && lane_dormant team && ok "lane_dormant: rows keyed max and team are subscription-1's and subscription-2's, asked by either word" || bad "lane_dormant"
[ "$(lane_state_field max 3)" = "login changed" ] && [ "$(lane_state_field $S2 3)" = "seat gone" ] && [ "$(lane_state_field team 6)" = hand ] && ok "lane_state_field reads the old rows' reason and setter" || bad "state field: $(lane_state_field max 3) / $(lane_state_field $S2 3)"
[ "$(lane_home a)" = $S1 ] && ok "lane_home: a home record saying max reads as subscription-1" || bad "lane_home: $(lane_home a)"
[ "$(lane_sessions_on $S1 | tr '\n' ' ')" = "a " ] && [ "$(lane_sessions_on team | tr '\n' ' ')" = "b " ] && ok "lane_sessions_on takes either word and lists the rows of the lane" || bad "sessions_on: '$(lane_sessions_on $S1 | tr '\n' ' ')' '$(lane_sessions_on team | tr '\n' ' ')'"
[ "$(SALA_LANE_FALLBACK="max=bedrock team=api bedrock=max" lane_fallback_of $S1)" = bedrock ] && [ "$(SALA_LANE_FALLBACK="max=bedrock team=api bedrock=max" lane_fallback_of team)" = api ] \
    && [ "$(SALA_LANE_FALLBACK="max=bedrock team=api bedrock=max" lane_fallback_of bedrock)" = $S1 ] && ok "SALA_LANE_FALLBACK written with the old words maps the new codes (the map's lane and its target)" || bad "fallback map: $(SALA_LANE_FALLBACK="max=bedrock team=api bedrock=max" lane_fallback_of bedrock)"
[ "$(lane_fallback_of $S1)" = bedrock ] && [ "$(lane_fallback_of $S2)" = bedrock ] && [ "$(lane_fallback_of bedrock)" = $S1 ] && ok "the default fallback map is written in the new codes" || bad "default fallback: $(lane_fallback_of $S1) $(lane_fallback_of bedrock)"
( job_env_args max && [ "${#JOB_ENV[@]}" -gt 0 ] && ! printf '%s\n' "${JOB_ENV[@]}" | grep -q = && a=("${JOB_ENV[@]}") && job_env_args $S1 && [ "${JOB_ENV[*]}" = "${a[*]}" ] ) && grep -q ': "${SALA_JOB_LANE:=subscription-1}"' "$ROOT/lib/common.sh" && ok "SALA_JOB_LANE=max (the harness's old word) runs as subscription-1, and the default is subscription-1" || bad "SALA_JOB_LANE handling"
rm -f "$SALA_LANE_STATE" "$SALA_LANE_DEFAULT_FILE"   # nothing dormant, no default recorded: the typed words below are accepted
err=$("$SALA" lane default team 2>&1 >/dev/null); rc=$?
[ "$rc" = 0 ] && [ "$(<"$SALA_LANE_DEFAULT_FILE")" = $S2 ] && grep -q "team is the old name of the $S2 lane" <<< "$err" && ok "sala lane default team: accepted, says once it is the old name, records subscription-2" || bad "lane default team ($rc): $err / $(<"$SALA_LANE_DEFAULT_FILE")"
"$SALA" lane default max >/dev/null 2>&1; [ "$(<"$SALA_LANE_DEFAULT_FILE")" = $S1 ] && ok "sala lane default max records subscription-1" || bad "lane default max: $(<"$SALA_LANE_DEFAULT_FILE")"
out=$("$SALA" op --plan lane default team 2>&1); rc=$?; [ "$rc" = 0 ] && grep -q "$S2" <<< "$out" && ok "sala op --plan lane default team: planned on subscription-2" || bad "op plan ($rc): $out"
out=$("$SALA" spawn lc-probe --lane team --dry-run 2>&1); rc=$?; [ "$rc" = 0 ] && grep -q -e "$S2" -e 'Team' <<< "$out" && ! grep -q -e 'unknown lane' -e 'is not a lane' <<< "$out" && ok "sala spawn --lane team (dry run): accepted and carried as subscription-2" || bad "spawn --lane team ($rc): $out"
python3 -I - "$ROOT/lib" <<'PY' && ok "the Python helpers: sessions.norm_lane, lanewords.norm_lane and unitjob.LANES use the new codes and read the old words" || bad "python helpers"
import sys
sys.path.insert(0, sys.argv[1]); import sessions, lanewords, unitjob
for mod in (sessions, lanewords):
    assert mod.norm_lane("max") == "subscription-1" and mod.norm_lane("team") == "subscription-2", mod
    assert mod.norm_lane("awsplatform") == "aws-platform" and mod.norm_lane("api") == "api" and mod.norm_lane(None) is None, mod
assert "subscription-1" in unitjob.LANES and "subscription-2" in unitjob.LANES and "max" not in unitjob.LANES and "team" not in unitjob.LANES, unitjob.LANES
PY

echo "== 3. new writes use the new codes"
printf 'a\tmax\nb\tteam\nc\tapi\n' > "$SALA_LANES"; echo max > "$SALA_LANE_DEFAULT_FILE"
printf 'max\tdormant\tlogin changed\t%s\t\tsignal\nteam\tdormant\tseat gone\t%s\t\thand\n' $OLDSTAMP $OLDSTAMP > "$SALA_LANE_STATE"
lane_write n max; lane_write m team; lane_write o $S2
grep -qP '^n\tsubscription-1$' "$SALA_LANES" && grep -qP '^m\tsubscription-2$' "$SALA_LANES" && grep -qP '^o\tsubscription-2$' "$SALA_LANES" && ! grep -qP '^[nmo]\t(max|team)$' "$SALA_LANES" && ok "lane_write max / team records subscription-1 / subscription-2" || bad "lanes.tsv: $(<"$SALA_LANES")"
grep -qP '^a\tmax$' "$SALA_LANES" && ok "a write rewrites only its own row: another session's old row keeps its word" || bad "carried rows: $(<"$SALA_LANES")"
lane_set_default team; [ "$(<"$SALA_LANE_DEFAULT_FILE")" = $S2 ] && ok "lane_set_default team records subscription-2" || bad "default: $(<"$SALA_LANE_DEFAULT_FILE")"
lane_set_default max; [ "$(<"$SALA_LANE_DEFAULT_FILE")" = $S1 ] && ok "lane_set_default max records subscription-1" || bad "default: $(<"$SALA_LANE_DEFAULT_FILE")"
lane_dormant_clear max "test" >/dev/null; grep -qP '^subscription-1\tactive' "$SALA_LANE_STATE" && ! grep -qP '^max\t' "$SALA_LANE_STATE" && [ "$(grep -c '' "$SALA_LANE_STATE")" = 2 ] && ! lane_dormant $S1 && lane_dormant $S2 \
    && ok "lane_dormant_clear on an old-keyed row: ONE subscription-1 row (active), no max row left beside it, the team row still dormant" || bad "state after clear: $(<"$SALA_LANE_STATE")"
lane_dormant_set team "again" hand >/dev/null; [ "$(grep -c '' "$SALA_LANE_STATE")" = 2 ] && grep -qP '^subscription-2\tdormant' "$SALA_LANE_STATE" && ! grep -qP '^team\t' "$SALA_LANE_STATE" \
    && ok "lane_dormant_set by the old word replaces the old row: still two rows, keyed subscription-2" || bad "state after set: $(<"$SALA_LANE_STATE")"
lane_dormant_set max "later" hand >/dev/null; grep -qP '^subscription-1\tdormant\tlater' "$SALA_LANE_STATE" && [ "$(grep -c '' "$SALA_LANE_STATE")" = 2 ] && ok "lane_dormant_set max records subscription-1" || bad "state after set max: $(<"$SALA_LANE_STATE")"
python3 -I - "$ROOT/lib" <<'PY' && ok "unitjob: a unit saying X-Model-Lane=team is read as subscription-2 (lanewords.norm_lane on the read)" || bad "unitjob read"
import sys
sys.path.insert(0, sys.argv[1]); import lanewords
assert lanewords.norm_lane("team") == "subscription-2" and lanewords.norm_lane("subscription-2") == "subscription-2"
PY

echo "== 4. a read rewrites nothing"
printf 'a\tmax\nb\tteam\nc\tawsplatform\nd\tbedrock\n' > "$SALA_LANES"; echo team > "$SALA_LANE_DEFAULT_FILE"
printf 'max\tdormant\tlogin changed\t%s\t\tsignal\nteam\tactive\t\t%s\t\t\n' $OLDSTAMP $OLDSTAMP > "$SALA_LANE_STATE"
printf 'a\tmax\t%s\t-\n' $OLDSTAMP > "$SALA_LANE_HOME"
rm -f "$STATE/lane-names.json"
sums0=$(snapf "$SALA_LANES" "$SALA_LANE_DEFAULT_FILE" "$SALA_LANE_STATE" "$SALA_LANE_HOME")
lane_row a >/dev/null; lane_row b >/dev/null; lane_default >/dev/null; lane_for_session a >/dev/null; lane_dormant max; lane_dormant team; lane_state_field max 3 >/dev/null; lane_home a >/dev/null
lane_sessions_on max >/dev/null; lane_out max >/dev/null 2>&1; lane_out team >/dev/null 2>&1; lane_names_json >/dev/null; lane_names_text >/dev/null; lane_label max >/dev/null; lane_shown team >/dev/null
"$SALA" lane >/dev/null 2>&1; "$SALA" lane --list >/dev/null 2>&1; "$SALA" lane --json >/dev/null 2>&1; "$SALA" lane names >/dev/null 2>&1; "$SALA" lane names --json >/dev/null 2>&1
[ "$(snapf "$SALA_LANES" "$SALA_LANE_DEFAULT_FILE" "$SALA_LANE_STATE" "$SALA_LANE_HOME")" = "$sums0" ] && ok "lanes.tsv, lane-default, lane-state.tsv and lane-home.tsv are byte-identical after every reader ran" || bad "a read rewrote a file: $(<"$SALA_LANES") | $(<"$SALA_LANE_STATE")"
[ ! -e "$STATE/lane-names.json" ] && ok "and a plain read (lane names, no --write) wrote no lane-names.json" || bad "lane names wrote the state file without --write"
grep -qP '^a\tmax$' "$SALA_LANES" && grep -qP '^max\tdormant' "$SALA_LANE_STATE" && ok "the old words are still in the files (nothing was migrated)" || bad "old words gone"
[ -z "$(ls "$STATE" | grep -E 'pre-(subscription|aws)')" ] && ok "no backup or migration file appeared" || bad "files: $(ls "$STATE")"
"$SALA" lane --migrate --dry-run >/dev/null 2>&1; grep -qP '^a\tmax$' "$SALA_LANES" && ok "lane --migrate moves only awsplatform: max and team rows stay" || bad "migrate touched max"

echo "== 5. the display name"
[ "$(lane_label $S1)" = Ultra ] && [ "$(lane_label max)" = Ultra ] && [ "$(lane_label $S2)" = Team ] && [ "$(lane_label team)" = Team ] && [ "$(lane_label api)" = API ] \
    && [ "$(lane_label bedrock)" = Bedrock ] && [ "$(lane_label aws-platform)" = "Claude Platform on AWS" ] && ok "lane_label: Ultra / Team / API / Bedrock / Claude Platform on AWS, by code or by old word" || bad "lane_label: $(lane_label $S1) $(lane_label team)"
[ "$(lane_shown max)" = Ultra ] && [ "$(lane_shown $S2)" = Team ] && [ "$(lane_shown api)" = api ] && [ "$(lane_shown bedrock)" = bedrock ] && ok "lane_shown: the display name for a subscription lane, any other word as it came" || bad "lane_shown: $(lane_shown max) $(lane_shown api)"
( SALA_LANE_SUBSCRIPTION1_LABEL=Zeta; [ "$(lane_label $S1)" = Zeta ] && [ "$(lane_label max)" = Zeta ] && [ "$(lane_shown max)" = Zeta ] && [ "$(lane_label $S2)" = Team ] ) && ok "SALA_LANE_SUBSCRIPTION1_LABEL changes the name for the code, the old word and lane_shown (the other lane untouched)" || bad "label override"
( SALA_LANE_MAX_LABEL=Legacy; [ "$(lane_label $S1)" = Legacy ] ) && ok "the config written before (SALA_LANE_MAX_LABEL) still sets the name" || bad "old label name"
( SALA_LANE_SUBSCRIPTION2_LABEL="Second seat"; [ "$(lane_label team)" = "Second seat" ] ) && ok "SALA_LANE_SUBSCRIPTION2_LABEL sets the second lane's name" || bad "subscription-2 label"
out=$("$SALA" lane --list 2>&1); grep -q 'Ultra' <<< "$out" && ok "sala lane --list shows the display name" || bad "lane --list: $out"
out=$(SALA_LANE_SUBSCRIPTION1_LABEL=Zeta "$SALA" lane --list 2>&1); grep -q 'Zeta' <<< "$out" && ! grep -qw 'Ultra' <<< "$out" && ok "…and the setting changes what it shows, with no Ultra left" || bad "lane --list override: $out"
out=$(SALA_LANE_SUBSCRIPTION1_LABEL=Zeta "$SALA" lane help 2>&1; SALA_LANE_SUBSCRIPTION1_LABEL=Zeta "$SALA" lane nope 2>&1); ! grep -qw 'Ultra' <<< "$out" && ok "the lane usage text spells no display name of its own (Zeta set: no Ultra anywhere)" || bad "usage text spells Ultra"
# the Python twin: from the state file, else by asking sala; the setting honoured either way
"$SALA" lane names --write >/dev/null 2>&1
python3 -I - "$ROOT/lib" "$STATE" <<'PY' && ok "lanewords.lane_label (Python) reads lane-names.json: Ultra / Team / API, by code or old word; an unknown lane shows its own code" || bad "python lane_label (state file)"
import os, sys
sys.path.insert(0, sys.argv[1]); os.environ["SALA_STATE_DIR"] = sys.argv[2]; import lanewords
assert lanewords.lane_label("subscription-1") == "Ultra" and lanewords.lane_label("max") == "Ultra", lanewords.lane_label("max")
assert lanewords.lane_label("team") == "Team" and lanewords.lane_label("api") == "API"
assert lanewords.lane_label("nonesuch") == "nonesuch"
PY
rm -f "$STATE/lane-names.json"
python3 -I - "$ROOT/lib" "$STATE" <<'PY' && ok "with no state file the Python twin answers from its fixed defaults (Ultra, Team, any other lane its own code) and runs no command" || bad "python lane_label (no file)"
import os, sys, subprocess
sys.path.insert(0, sys.argv[1]); os.environ["SALA_STATE_DIR"] = sys.argv[2]; import lanewords
def boom(*a, **k): raise AssertionError("a command was run")
subprocess.run = boom; subprocess.Popen = boom; os.system = boom
assert lanewords.lane_label("max") == "Ultra" and lanewords.lane_label("subscription-1") == "Ultra", lanewords.lane_label("max")
assert lanewords.lane_label("team") == "Team" and lanewords.lane_label("api") == "api" and lanewords.lane_label("nonesuch") == "nonesuch"
PY
# the parsed table is cached per process, keyed on the file: read once while it is unchanged, read again when it changes
python3 -I - "$ROOT/lib" "$STATE" <<'PY' && ok "lanewords parses lane-names.json once per process while it is unchanged, and again when it changes" || bad "python lane_label cache"
import builtins, json, os, sys
sys.path.insert(0, sys.argv[1]); st = sys.argv[2]; os.environ["SALA_STATE_DIR"] = st; import lanewords
f = os.path.join(st, "lane-names.json")
def put(display, size_pad=""):
    t = f + ".t"
    with open(t, "w") as h: json.dump({"lanes": [{"code": "subscription-1", "display": display + size_pad, "aliases": ["max"]}]}, h)
    os.replace(t, f)
put("Alpha")
opened = []; real = builtins.open
def spy(p, *a, **k):
    if str(p) == f: opened.append(1)
    return real(p, *a, **k)
builtins.open = spy
assert [lanewords.lane_label("max") for _ in range(50)] == ["Alpha"] * 50 and len(opened) == 1, len(opened)
put("Bravo"); assert lanewords.lane_label("max") == "Bravo" and len(opened) == 2, len(opened)
os.remove(f); assert lanewords.lane_label("max") == "Ultra"
PY

echo "== 6. sala lane names"
out=$("$SALA" lane names 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(wc -l <<< "$out")" = "$(wc -w <<< "$SALA_LANES_KNOWN")" ] && [ "$(awk -F'\t' 'NF != 3 {n++} END {print n + 0}' <<< "$out")" = 0 ] && ok "the text form: one line per known lane, three tab-separated columns" || bad "lane names text ($rc): $out"
[ "$(sed -n 1p <<< "$out" | tr '\t' '|')" = "$S1|Ultra|max" ] && grep -q "^$S2	Team	team$" <<< "$out" && grep -q '^api	API	$' <<< "$out" && ok "…code, display name, old words (subscription-1 Ultra max; subscription-2 Team team; api API with none)" || bad "lane names lines: $out"
out=$("$SALA" lane names --json 2>&1); rc=$?
python3 -I - "$out" "$SALA_LANES_KNOWN" <<'PY' && [ "$rc" = 0 ] && ok "--json: exactly {\"lanes\":[{code, display, aliases}]}, every known lane in order, aliases [] when none" || bad "lane names --json ($rc): $out"
import json, sys
d = json.loads(sys.argv[1])
assert list(d) == ["lanes"], list(d)
assert [r["code"] for r in d["lanes"]] == sys.argv[2].split(), [r["code"] for r in d["lanes"]]
for r in d["lanes"]:
    assert list(r) == ["code", "display", "aliases"], r
    assert isinstance(r["code"], str) and isinstance(r["display"], str) and r["display"] and isinstance(r["aliases"], list), r
by = {r["code"]: r for r in d["lanes"]}
assert by["subscription-1"] == {"code": "subscription-1", "display": "Ultra", "aliases": ["max"]}, by["subscription-1"]
assert by["subscription-2"] == {"code": "subscription-2", "display": "Team", "aliases": ["team"]}, by["subscription-2"]
assert by["api"]["aliases"] == [] and by["bedrock"]["aliases"] == [] and by["aws-platform"]["aliases"] == ["awsplatform"], by
PY
out=$(SALA_LANE_SUBSCRIPTION1_LABEL=Zeta "$SALA" lane names --json 2>&1); grep -q '"code":"subscription-1","display":"Zeta"' <<< "$out" && ! grep -q Ultra <<< "$out" && ok "the setting shows in --json (Zeta, no Ultra)" || bad "lane names override: $out"
out=$("$SALA" lane names --bogus 2>&1); rc=$?; [ "$rc" != 0 ] && grep -q 'usage: salamander lane names' <<< "$out" && ok "an unknown flag prints the usage and fails" || bad "lane names --bogus ($rc): $out"
"$SALA" lane --help 2>&1 | grep -q 'lane names' && ok "lane --help lists the names verb" || bad "lane --help does not list names"

echo "== 7. lane-names.json: atomic, and only on change"
F="$STATE/lane-names.json"; rm -f "$F"
out=$("$SALA" lane names --write 2>&1 >/dev/null); [ -s "$F" ] && python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$F" && ok "lane names --write writes a valid lane-names.json" || bad "write: $out"
cmp -s "$F" <("$SALA" lane names --json) && ok "…the same JSON lane names --json prints" || bad "file differs from --json"
ino0=$(stat -c %i "$F"); mt0=$(stat -c %y "$F"); sleep 1.1
lane_names_write >/dev/null; "$SALA" lane names --write >/dev/null 2>&1
[ "$(stat -c %i "$F")" = "$ino0" ] && [ "$(stat -c %y "$F")" = "$mt0" ] && ok "written again with nothing changed: same inode, same mtime (no rewrite)" || bad "an unchanged write rewrote the file"
[ "$(lane_names_write)" = unchanged ] && ok "and the writer says unchanged" || bad "writer answer: $(lane_names_write)"
SALA_LANE_SUBSCRIPTION1_LABEL=Zeta lane_names_write >/dev/null; grep -q Zeta "$F" && [ "$(stat -c %i "$F")" != "$ino0" ] && ok "a changed name rewrites it (a new file moved into place: a new inode)" || bad "a change was not written"
[ -z "$(ls -A "$STATE" | grep -F 'lane-names' | grep -v '^lane-names.json$')" ] && [ -z "$(find "$STATE" -maxdepth 1 -name '.lane-names.*')" ] && ok "no temp file is left behind" || bad "leftovers: $(ls -A "$STATE")"
# a reader never sees half a file: one writer alternates the setting while this shell reads the file 300 times
( for i in $(seq 1 40); do if [ $((i % 2)) = 0 ]; then SALA_LANE_SUBSCRIPTION1_LABEL=Alpha lane_names_write >/dev/null; else SALA_LANE_SUBSCRIPTION1_LABEL=Omega lane_names_write >/dev/null; fi; done ) &
WPID=$!; PIDS="$PIDS $WPID"
badreads=0; n=0
while kill -0 "$WPID" 2>/dev/null && [ $n -lt 300 ]; do
    python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert len(d["lanes"]) >= 5' "$F" 2>/dev/null || badreads=$((badreads + 1)); n=$((n + 1))
done
wait "$WPID"; PIDS=""
[ "$badreads" = 0 ] && [ "$n" -gt 0 ] && ok "$n reads while the file was being rewritten: every one a whole, valid JSON (atomic: temp file, then mv)" || bad "$badreads of $n reads saw a broken file"
# the watch's tick keeps the file current (a plain tick, no master, no tmux server)
# the tick does the work only when something changed: the file missing, the config newer than it, or sala's own code newer (three bash tests, no process).
# A config file of this suite's own stands in for ~/.config/salamander/config (SALA_CONFIG=/dev/null has no age of its own to test), and the code is a
# copy of the tree under $HOME, so the age of lib/common.sh can be set without touching the checkout.
CP="$HOME/tree"; mkdir -p "$CP"; cp -r "$ROOT/bin" "$ROOT/lib" "$CP/" 2>/dev/null
tickw() { SALA_BIN="$CP/bin/salamander" SALA_ROOT="$CP" "$CP/bin/salamander" watch >/dev/null 2>&1; }
CFG="$HOME/sala-config"; : > "$CFG"; export SALA_CONFIG="$CFG"
touch -d '2 minutes ago' "$CFG" "$CP/lib/common.sh"; touch -d '1 minute ago' "$F"
rm -f "$F"; tickw
[ -s "$F" ] && cmp -s "$F" <("$SALA" lane names --json) && ok "sala watch's tick with no lane-names.json writes it (the same JSON lane names --json prints)" || bad "the tick did not write the file"
touch -d '1 minute ago' "$F"; ino1=$(stat -c %i "$F"); mt1=$(stat -c %y "$F"); tickw
[ "$(stat -c %i "$F")" = "$ino1" ] && [ "$(stat -c %y "$F")" = "$mt1" ] && [ -z "$(find "$STATE" -maxdepth 1 -name '.lane-names.*')" ] && ok "a second tick, nothing changed: the file is not touched (same inode, same mtime) and no temp file is left" || bad "a second tick did work"
# proof it skipped the build: a name the file does not hold stays out of it (an env-only change is no config change)
SALA_LANE_SUBSCRIPTION1_LABEL=Zeta tickw; ! grep -q Zeta "$F" && [ "$(stat -c %i "$F")" = "$ino1" ] && ok "…and the tick does not even look at the names while nothing is newer (an environment-only change is not picked up)" || bad "the tick rebuilt with nothing newer"
printf 'SALA_LANE_SUBSCRIPTION1_LABEL=Zeta\n' > "$CFG"; tickw
grep -q Zeta "$F" && [ "$(stat -c %i "$F")" != "$ino1" ] && ok "touching the config: the next tick rewrites the file with the new name" || bad "the tick did not follow the config"
ino2=$(stat -c %i "$F"); mt2=$(stat -c %y "$F"); sleep 1.1; tickw
[ "$(stat -c %i "$F")" = "$ino2" ] && [ "$(stat -c %y "$F")" = "$mt2" ] && ok "…and the tick after that leaves it alone again" || bad "a tick after the rewrite did work"
touch -d '3 seconds ago' "$F"; sleep 0.2; touch "$CFG"; mt3=$(stat -c %Y "$F"); tickw
[ "$(stat -c %Y "$F")" -gt "$mt3" ] && ! [ "$CFG" -nt "$F" ] && ok "a config touched with no name changed: the tick finds the same content, marks the file checked, and the next tick skips" || bad "a no-change config touch is rechecked every tick"
touch -d '1 minute ago' "$F"; touch "$CP/lib/common.sh"; mt4=$(stat -c %Y "$F"); tickw
[ "$(stat -c %Y "$F")" -gt "$mt4" ] && ok "sala's own code newer than the file (a release): the tick checks the names again" || bad "newer code did not trigger a check"
unset SALA_CONFIG; export SALA_CONFIG=/dev/null

# the limit watch's stored state: a lane's newest success (laneok) kept under both the old word and the new code reads as ONE key holding the
# larger epoch (the newer success), in either order of the two keys, and the rewritten state carries the new code only
LS="$SALA_LIMIT_STATE"; mkdir -p "$(dirname "$LS")"
lanes_ok() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1]))["laneok"]; print(" ".join("%s=%s" % kv for kv in sorted(d.items())))' "$LS"; }
for order in old-last new-last; do
    if [ $order = old-last ]; then lo='{"subscription-1|":900,"max|":100,"subscription-2|":50,"team|":700,"api|":5,"max|seven_day":300,"subscription-1|seven_day":200}'
    else lo='{"max|":100,"subscription-1|":900,"team|":700,"subscription-2|":50,"api|":5,"subscription-1|seven_day":200,"max|seven_day":300}'; fi
    printf '{"panes":{},"done":{},"seen":{},"pok":{},"laneok":%s,"headless":{},"pseen":{},"hseen":{},"episode":0}\n' "$lo" > "$LS"
    "$SALA" watch --limit >/dev/null 2>&1; got=$(lanes_ok)
    [ "$got" = "api|=5 subscription-1|=900 subscription-1|seven_day=300 subscription-2|=700" ] && ok "laneok with an old-word key and its new code's key ($order): one key, the larger (newer) success wins" || bad "laneok merge ($order): $got"
done

echo "== 8. no user-visible \"Max\" / \"Team lane\" for our lane"
# Every line of lib/ bin/ web/src (code, text, JS, HTML) that spells Max, MAX or "max/team lane" is looked at, comments excluded; what is
# allowed is Anthropic's own plan names and the table's own definitions of the old words. Nothing else may spell the display name.
ALLOW='subscriptionType|PLAN_NAMES|PLAN_WORDS|max_5x|max_20x|max_20|team_standard|team_premium|Max \(20x\)|Max 5x|Max 20x|Max plan|Max subscription|Max login|a Max account|SALA_LANE_MAX_|SALA_FOLLOW_MAX|_lane_varid_old_r|SALA_LANE_RENAMED|lane_expect|sw_sub_words|no longer reports Max|limits for Max and Team|SALA_LANE_TEAM_DIR|--max|max_args|backoff_max|max_turns'
files=$(cd "$ROOT" && find lib bin web/src -type f \( -name '*.sh' -o -name '*.py' -o -name '*.js' -o -name '*.html' -o -name '*.css' -o -name salamander \) 2>/dev/null | grep -v -e '/node_modules/' -e '/__pycache__/')
hits=$(cd "$ROOT" && grep -n -w -e 'Max' -e 'Team lane' -e 'team lane' -e 'max lane' -e 'Max lane' $files 2>/dev/null \
    | grep -v -E '^[^:]*:[0-9]+:[[:space:]]*(#|//|\*|/\*|<!--)' | grep -v -E "$ALLOW" | grep -v -e 'lane_label' -e 'lane_shown')
[ -z "$hits" ] && ok "no line spells Max, a max lane or a Team lane outside comments, the plan allow-list and the label helpers" || { bad "a display name is spelled outside the setting:"; echo "$hits" | cut -c1-200 | sed 's/^/        /'; }
cfg=$(cd "$ROOT" && grep -n -E '"(Ultra)"|=Ultra|:-Ultra|Ultra\)' $files 2>/dev/null | grep -v -E '^[^:]*:[0-9]+:[[:space:]]*(#|//)')
n_ultra=$(grep -c . <<< "$cfg"); only_table=1; while IFS= read -r l; do [ -z "$l" ] && continue; grep -q -e 'lib/common.sh' -e 'lib/lanewords.py' <<< "$l" || only_table=0; done <<< "$cfg"
[ "$only_table" = 1 ] && ok "\"Ultra\" is spelled only where the lane-fields table defines it (lib/common.sh) and in the Python twin's no-file fallback (lib/lanewords.py), not in any message or UI file" || { bad "Ultra is spelled outside the table:"; echo "$cfg" | cut -c1-200 | sed 's/^/        /'; }
doc=$(cd "$ROOT" && grep -n 'Ultra' README.md config.example | head -3 | wc -l); [ "$doc" -gt 0 ] && ok "README.md and config.example document the setting" || bad "the setting is not documented"

[ "$fail" = 0 ] && echo "lane-subscription-codes: pass" || echo "lane-subscription-codes: FAIL"
exit "$fail"
