#!/usr/bin/env bash
# The lane fields (lib/common.sh "THE LANE FIELDS", lib/lane.sh --list / --json): what a lane
# IS (provider, client, org, billing, plan, account, credential, region, status), apart from how it launches. Fields only:
# nothing is launched and no lane changes. What is checked: every field of subscription-1, subscription-2, api, bedrock and aws-platform as the spec states it
# (and the values in the spec's lists); an override from config (SALA_LANE_<ID>_<FIELD>) winning, and a value outside its
# list flagged; an unknown word is no lane (lane_known fails; lane_check / `sala lane <word> …` / `lane default <word>` / spawn refuse it);
# bedrock known, refused while its AWS profile is missing (the launch itself is tests/bedrocklane.sh); aws-platform known, refused while its workspace id is empty (tests/aws-platform-lane.sh); sdk folded into api as an ALIAS (accepted wherever it was, client
# claude-agent-sdk, its SDK settings still its own); `sala lane --list` an aligned table, `--json` parsing with the same
# five lanes and null for a field a lane leaves out, the no-argument table carrying it too; lanes.tsv unchanged in format
# and never rewritten by any read-only form or refusal (an unknown-word or sdk row stays byte for byte, the unknown row flagged under
# the table and launched on the default). No tmux server is started: the private socket named below never exists, so the
# table finds no panes and the live fleet is never asked. Isolated HOME. Usage: bash tests/lanefields.sh (exit 0 = pass; ~5 s)
set -u
unset TMUX_PANE XDG_STATE_HOME SALA_SET SALA_SET_SELF SALA_POST_RECYCLE_CMD SALA_RECYCLE SALA_RETRY_WORKER SALA_NO_RELAUNCH SALA_MASTER
unset ANTHROPIC_API_KEY ANTHROPIC_CUSTOM_HEADERS CLAUDE_CONFIG_DIR SALA_LANE_API_KEY_FILE SALA_LANE_API_WORKSPACE_FILE SALA_LANE_API_MCP_CONFIG SALA_LANE_TEAM_DIR
for v in $(compgen -v | grep -E '^SALA_LANE_(MAX|TEAM|API|BEDROCK|AWSPLATFORM)_(LABEL|PROVIDER|CLIENT|ORG|PROJECT|BILLING|PAYMENT|PLAN|ACCOUNT|CREDENTIAL|REGION|STATUS)$'); do unset "$v"; done
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"   # short timings, ok/bad/waitfor
unset SALA_LANE_BEDROCK_REGION SALA_LANE_AWSPLATFORM_REGION   # lib.sh's fixture regions: this suite reads the table's own value, which is empty (no region has a default)
export HOME=$(mktemp -d); export SALA_CONFIG=/dev/null SALA_TZ=Etc/UTC
mkdir -p "$HOME/.claude" "$HOME/.local/bin"
# a stand-in for the CLI at the path spawn checks first ("claude not found" comes before the lane check; a CI runner has none under
# this HOME): nothing here runs it, the unknown-lane refusal comes before any launch
printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/claude"; chmod +x "$HOME/.local/bin/claude"
export SALA_BIN="$ROOT/bin/salamander" SALA_ROOT="$ROOT" SALA_AUTO_UPDATE=off SALA_AUTO_RECYCLE=off SALA_AGENT_CHECK=off
SALA="$ROOT/bin/salamander"; SOCK="sala-lanefields-$$"
unset TMUX; export SALA_TMUX_SOCKET="${TMUX_TMPDIR:-/tmp}/tmux-$EUID/$SOCK"   # never started: the table finds no panes
cleanup() { rm -rf "$HOME" 2>/dev/null; true; }; trap cleanup EXIT
eval "tmux() { command tmux -L $SOCK -f /dev/null \"\$@\"; }"; export -f tmux    # literal socket: nothing here reaches the fleet's server
. "$ROOT/lib/common.sh"
STATE="$SALA_STATE_DIR"; mkdir -p "$STATE"

# want <lane> <field> <value> — one field as the spec states it (an empty value = the lane leaves the field out)
want() { local got; got=$(lane_field "$1" "$2"); [ "$got" = "$3" ] && ok "$1 $2: ${3:-(none)}" || bad "$1 $2: '$got', expected '${3:-(none)}'"; }

echo "== the fields of each lane, as the spec states them"
want subscription-1 id subscription-1;               want subscription-1 label Ultra;        want subscription-1 provider anthropic; want subscription-1 client claude-code
want subscription-1 org unconfirmed;      want subscription-1 project ""
want max billing subscription; want max payment "";       want max plan ""
want subscription-1 account unconfirmed;   want subscription-1 credential login;   want subscription-1 region "";   want subscription-1 status active
want subscription-2 id subscription-2;             want subscription-2 label Team;      want subscription-2 provider anthropic; want subscription-2 client claude-code
want subscription-2 org unconfirmed;      want subscription-2 project "";      want subscription-2 billing subscription; want subscription-2 payment ""; want subscription-2 plan ""
want subscription-2 account unconfirmed;  want subscription-2 credential login;  want subscription-2 region "";  want subscription-2 status inactive
want api id api;               want api label API;        want api provider anthropic;  want api client claude-code
want api org unconfirmed;      want api billing usage;    want api payment prepaid;     want api plan ""
want api account unconfirmed;   want api region "";  want api status inactive
cred=$(lane_field api credential)
case "$cred" in "key file ~/.config/anthropic/api-key + workspace id file ~/.config/anthropic/workspace-id") ok "api credential: the key file plus the workspace id file (paths, never a value)";; *) bad "api credential: '$cred'";; esac
want bedrock id bedrock;       want bedrock label Bedrock; want bedrock provider amazon-bedrock; want bedrock client claude-code
want bedrock org "AWS account";  want bedrock billing usage; want bedrock payment postpaid; want bedrock plan ""
want bedrock account unconfirmed;  want bedrock credential "AWS profile";  want bedrock region "";  want bedrock status "not set up"
want aws-platform id aws-platform;  want aws-platform label "Claude Platform on AWS";  want aws-platform provider anthropic;  want aws-platform client claude-code
want aws-platform org "AWS-linked Anthropic organization";  want aws-platform project "";  want aws-platform billing usage;  want aws-platform payment postpaid;  want aws-platform plan ""
want aws-platform account unconfirmed;  want aws-platform credential "AWS profile";  want aws-platform region "";  want aws-platform status "not set up"
[ "$SALA_LANES_DEFINED" = "subscription-1 subscription-2 api bedrock aws-platform" ] && ok "five lanes defined, in the spec's order" || bad "SALA_LANES_DEFINED: $SALA_LANES_DEFINED"
[ "$SALA_LANE_FIELDS" = "id label provider client org project billing payment plan account credential region status" ] && ok "the field set and its order" || bad "SALA_LANE_FIELDS: $SALA_LANE_FIELDS"
n=0; for l in $SALA_LANES_DEFINED; do p=$(lane_fields_problems "$l"); [ -z "$p" ] && n=$((n+1)) || bad "$p"; done
[ "$n" = 5 ] && ok "every lane's defaults hold to the spec's lists (provider, client, billing, payment, plan, status; no plan on usage, no payment on a subscription)" || bad "problems in the defaults"
lane_field subscription-1 nosuchfield >/dev/null 2>&1 && bad "an unknown field answered" || ok "an unknown field: refused"
lane_field bogus org >/dev/null 2>&1 && bad "an unknown lane has fields" || ok "an unknown lane has no fields"

echo "== config overrides a field; a value outside its list is flagged"
[ "$(SALA_LANE_API_ORG=Example-Org lane_field api org)" = Example-Org ] && ok "SALA_LANE_API_ORG=Example-Org wins over 'unconfirmed'" || bad "override: $(SALA_LANE_API_ORG=Example-Org lane_field api org)"
[ "$(SALA_LANE_MAX_ACCOUNT=alice@example.com lane_field max account)" = alice@example.com ] && ok "SALA_LANE_MAX_ACCOUNT names the account" || bad "account override"
[ "$(SALA_LANE_MAX_ACCOUNT=alice@example.com lane_field max org)" = "alice@example.com's Organization" ] && ok "a max account named: the org field follows it (a login's organization is named after its email)" || bad "max org follows the account: $(SALA_LANE_MAX_ACCOUNT=alice@example.com lane_field max org)"
[ "$(SALA_LANE_BEDROCK_ORG='AWS account via Example Reseller' lane_field bedrock org)" = "AWS account via Example Reseller" ] && ok "SALA_LANE_BEDROCK_ORG wins over the plain default" || bad "bedrock org override"
[ "$(SALA_LANE_BEDROCK_REGION=us-east-1 lane_field bedrock region)" = us-east-1 ] && ok "SALA_LANE_BEDROCK_REGION fills the region" || bad "region override"
[ "$(SALA_LANE_AWSPLATFORM_REGION=us-east-1 lane_field aws-platform region)" = us-east-1 ] && ok "SALA_LANE_AWSPLATFORM_REGION fills the region" || bad "aws-platform region override"
[ "$(SALA_LANE_MAX_ID=other lane_field max id)" = subscription-1 ] && ok "the id cannot be overridden" || bad "id overridden"
p=$(SALA_LANE_MAX_PROVIDER=openai lane_fields_problems max); [ -z "$p" ] && ok "a provider in the list: fine" || bad "openai flagged: $p"
p=$(SALA_LANE_MAX_PROVIDER=bogus lane_fields_problems max); grep -q "provider 'bogus'" <<< "$p" && ok "an unknown provider: flagged" || bad "provider bogus: '$p'"
p=$(SALA_LANE_API_STATUS=broken lane_fields_problems api); grep -q "status 'broken'" <<< "$p" && ok "a status outside active|inactive|not set up: flagged" || bad "status: '$p'"
p=$(SALA_LANE_API_PLAN=max_5x lane_fields_problems api); grep -q 'plan belongs to a subscription' <<< "$p" && ok "usage billing with a plan: flagged" || bad "plan on usage: '$p'"
p=$(SALA_LANE_TEAM_PAYMENT=prepaid lane_fields_problems team); grep -q 'belongs to usage billing' <<< "$p" && ok "a subscription with a payment: flagged" || bad "payment on subscription: '$p'"
for pl in max_5x max_20x team_standard team_premium chatgpt_plus chatgpt_pro chatgpt_business google_ai_pro google_ai_ultra; do lane_field_valid plan $pl || bad "plan $pl refused"; done; lane_field_valid plan max && bad "plan 'max' accepted"; ok "the nine plans are valid, a tenth word is not"
for pr in anthropic openai google google-vertex amazon-bedrock azure; do lane_field_valid provider $pr || bad "provider $pr refused"; done
for cl in claude-code claude-agent-sdk codex gemini-cli; do lane_field_valid client $cl || bad "client $cl refused"; done; ok "the spec's providers and clients are valid"

echo "== an unknown word is no lane"
lane_known bogus && bad "lane_known bogus passed" || ok "lane_known bogus fails"
case " $SALA_LANES_KNOWN " in *" bogus "*) bad "bogus in SALA_LANES_KNOWN: $SALA_LANES_KNOWN";; *) ok "bogus is not in SALA_LANES_KNOWN ($SALA_LANES_KNOWN)";; esac
why=$(lane_check bogus); rc=$?
[ "$rc" = 1 ] && grep -q "unknown lane 'bogus'" <<< "$why" && grep -q '(one of: ' <<< "$why" && ok "lane_check bogus: unknown, with the lanes it could be" || bad "lane_check bogus ($rc): $why"
out=$("$SALA" lane bogus sala-test-a 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q "unknown lane 'bogus'" <<< "$out" && ok "sala lane bogus <session>: refused" || bad "lane bogus ($rc): $out"
out=$("$SALA" lane default bogus 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q "unknown lane 'bogus'" <<< "$out" && ok "sala lane default bogus: refused" || bad "lane default bogus ($rc): $out"
out=$("$SALA" spawn sala-test-x --lane bogus --dry-run 2>&1); rc=$?
grep -q "'bogus' is not a lane" <<< "$out" && ok "sala spawn --lane bogus: refused" || bad "spawn --lane bogus ($rc): $out"

echo "== bedrock: known, launchable once the profile is in the credentials file; here it is not"
lane_known bedrock && ok "lane_known bedrock" || bad "bedrock unknown"
why=$(lane_check bedrock); rc=$?
[ "$rc" = 1 ] && grep -q 'bedrock lane: no \[example-bedrock\] profile' <<< "$why" && ok "lane_check bedrock: refused, the missing profile named" || bad "lane_check bedrock ($rc): $why"
out=$("$SALA" lane default bedrock --dry-run 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q 'no \[example-bedrock\] profile' <<< "$out" && [ ! -e "$SALA_LANE_DEFAULT_FILE" ] && ok "sala lane default bedrock: refused, no default file written" || bad "lane default bedrock ($rc): $out"
[ "$(lane_field bedrock status)" = "not set up" ] && ok "bedrock's status is derived: not set up while lane_check refuses" || bad "bedrock status: $(lane_field bedrock status)"

echo "== aws-platform: known, launchable once the workspace id is set and the profile is in the credentials file; here neither is"
lane_known aws-platform && ok "lane_known aws-platform" || bad "aws-platform unknown"
why=$(lane_check aws-platform); rc=$?
[ "$rc" = 1 ] && grep -q 'aws-platform lane: no workspace id yet' <<< "$why" && ok "lane_check aws-platform: refused, the empty workspace id named" || bad "lane_check aws-platform ($rc): $why"
out=$("$SALA" lane default aws-platform --dry-run 2>&1); rc=$?
[ "$rc" = 1 ] && grep -q 'no workspace id yet' <<< "$out" && [ ! -e "$SALA_LANE_DEFAULT_FILE" ] && ok "sala lane default aws-platform: refused, no default file written" || bad "lane default aws-platform ($rc): $out"
[ "$(lane_field aws-platform status)" = "not set up" ] && ok "aws-platform's status is derived: not set up while lane_check refuses" || bad "aws-platform status: $(lane_field aws-platform status)"
[ "$(SALA_LANE_AWSPLATFORM_WORKSPACE_ID=wrkspc_01EXAMPLE lane_field aws-platform project)" = wrkspc_01EXAMPLE ] && ok "its project field is the workspace id knob" || bad "project field"

echo "== sdk is folded into api: an alias, accepted where it was, with client claude-agent-sdk"
lane_known sdk && ok "lane_known sdk: still a word sala accepts (rows in lanes.tsv, 'sala lane sdk <session>')" || bad "sdk unknown"
[ "$(lane_canonical sdk)" = api ] && [ "$(lane_canonical subscription-1)" = subscription-1 ] && ok "lane_canonical: sdk -> api, others as they are" || bad "canonical: $(lane_canonical sdk) $(lane_canonical subscription-1)"
[ "$(lane_field sdk client)" = claude-agent-sdk ] && [ "$(lane_field api client)" = claude-code ] && ok "sdk's client is claude-agent-sdk, api's claude-code" || bad "sdk client: $(lane_field sdk client)"
[ "$(lane_field sdk org)" = "$(lane_field api org)" ] && [ "$(lane_field sdk billing)" = usage ] && [ "$(lane_field sdk payment)" = prepaid ] && ok "every other sdk field is api's" || bad "sdk fields differ from api's"
case "$SALA_LANE_SDK_PIN" in claude-agent-sdk==*) ok "SALA_LANE_SDK_PIN keeps its name and default (the sdk client's setting; SALA_LANE_SDK_UNTIL is gone)";; *) bad "sdk settings: $SALA_LANE_SDK_PIN";; esac
[ "$(lane_env_names sdk)" = "$(lane_env_names api | sed 's/ ENABLE_PROMPT_CACHING_1H$//')" ] && [ "$(lane_env_names api)" != "$(lane_env_names sdk)" ] && ok "sdk and api hand the same environment names to the CLI, bar the api pane's own 1-hour cache switch (the sdk pane's line is no claude line)" || bad "env names differ"

echo "== sala lane --list and --json"
out=$("$SALA" lane --list 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(head -1 <<< "$out" | tr -s ' ' | cut -d' ' -f1-12)" = "ID LABEL PROVIDER CLIENT ORG PROJECT BILLING PLAN ACCOUNT CREDENTIAL REGION STATUS" ] && ok "--list: the header names the fields (payment folded into billing)" || bad "--list ($rc): $out"
rows=$(grep -cE '^(subscription-1|subscription-2|api|bedrock|aws-platform) ' <<< "$out"); [ "$rows" = 5 ] && ok "--list: one row per lane" || bad "--list rows: $rows"
c1=$(awk 'NR==1 {print index($0, "PROVIDER")}' <<< "$out"); same=1
for l in subscription-1 subscription-2 api bedrock aws-platform; do [ "$(awk -v l="$l" '$1==l {print index($0, "anthropic") + index($0, "amazon-bedrock")}' <<< "$out")" = "$c1" ] || same=0; done
[ "$c1" -gt 0 ] && [ "$same" = 1 ] && ok "--list: the columns line up (every provider starts under PROVIDER)" || bad "alignment: PROVIDER at $c1 / $out"
grep -q 'usage (prepaid)' <<< "$out" && grep -q 'usage (postpaid)' <<< "$out" && grep -q 'subscription' <<< "$out" && grep -q 'not set up' <<< "$out" && ok "--list: billing with its payment, the plan, the status" || bad "--list content: $out"
grep -q '^alias: sdk = api with client claude-agent-sdk' <<< "$out" && ok "--list: names the sdk alias" || bad "--list footer: $out"
grep -q '^⚠' <<< "$out" && bad "--list flags a default" || ok "--list: no warning on the defaults"
out2=$(SALA_LANE_MAX_PROVIDER=bogus "$SALA" lane --list 2>&1); grep -q "^⚠ subscription-1 lane: provider 'bogus'" <<< "$out2" && ok "--list: a bad override is flagged under the table" || bad "--list with a bad override: $out2"
[ "$(SALA_LANE_API_ORG=Example-Org "$SALA" lane --list 2>&1 | awk '$1=="api" && /Example-Org/ {f=1} END {print f+0}')" = 1 ] && ok "--list: a config override shows" || bad "--list override"
json=$("$SALA" lane --json 2>&1); rc=$?
JSON="$json" python3 - <<'PY' && ok "--json: valid JSON, five lanes, every field, null for what a lane leaves out, the sdk alias" || bad "--json ($rc): $json"
import json, os
d = json.loads(os.environ["JSON"])
assert [l["id"] for l in d["lanes"]] == ["subscription-1", "subscription-2", "api", "bedrock", "aws-platform"], d["lanes"]
f = "id label provider client org project billing payment plan account credential region status".split()
assert all(list(l) == f for l in d["lanes"]), [list(l) for l in d["lanes"]]
by = {l["id"]: l for l in d["lanes"]}
m, t, a, b, w = by["subscription-1"], by["subscription-2"], by["api"], by["bedrock"], by["aws-platform"]
assert (m["provider"], m["client"], m["org"], m["billing"], m["plan"], m["account"], m["credential"], m["status"]) == \
       ("anthropic", "claude-code", "unconfirmed", "subscription", None, "unconfirmed", "login", "active"), m
assert m["project"] is None and m["payment"] is None and m["region"] is None
assert (t["org"], t["billing"], t["plan"], t["status"]) == ("unconfirmed", "subscription", None, "inactive"), t
assert (a["billing"], a["payment"], a["plan"], a["status"], a["org"]) == ("usage", "prepaid", None, "inactive", "unconfirmed"), a
assert a["credential"].startswith("key file ") and "workspace id file" in a["credential"]
assert (b["provider"], b["billing"], b["payment"], b["account"], b["credential"], b["region"], b["status"]) == \
       ("amazon-bedrock", "usage", "postpaid", "unconfirmed", "AWS profile", None, "not set up"), b
assert (w["label"], w["provider"], w["client"], w["billing"], w["payment"], w["plan"], w["project"], w["credential"], w["region"], w["status"]) == \
       ("Claude Platform on AWS", "anthropic", "claude-code", "usage", "postpaid", None, None, "AWS profile", None, "not set up"), w
assert d["aliases"]["sdk"]["lane"] == "api" and d["aliases"]["sdk"]["client"] == "claude-agent-sdk" and d["default"] == "subscription-1"
PY
[ "$("$SALA" lane --list --json 2>&1 | head -c1)" = "{" ] && ok "--list --json is the JSON too" || bad "--list --json"
out=$("$SALA" lane --list sala-test-a 2>&1); rc=$?; [ "$rc" = 1 ] && ok "--list with a session: refused (read-only, takes nothing else)" || bad "--list sala-test-a ($rc): $out"
out=$("$SALA" lane --json --all 2>&1); rc=$?; [ "$rc" = 1 ] && ok "--json --all: refused" || bad "--json --all ($rc): $out"
out=$("$SALA" lane 2>&1); rc=$?
[ "$rc" = 0 ] && grep -q '^default lane: subscription-1' <<< "$out" && grep -q '^ID  *LABEL  *PROVIDER' <<< "$out" && grep -q '^lanes: subscription-1 ready' <<< "$out" && grep -q 'bedrock not ready' <<< "$out" && grep -q 'aws-platform not ready' <<< "$out" && ok "sala lane: the default line, the fields table, then the readiness line as before" || bad "sala lane ($rc): $out"

echo "== lanes.tsv: the format is unchanged and nothing rewrites a row"
printf 'sala-test-a\tsubscription-1\nsala-test-b\tsdk\nsala-test-c\tbogus\nsala-test-d\tsubscription-2\n' > "$SALA_LANES"
sum0=$(md5sum < "$SALA_LANES"); mt0=$(stat -c %Y.%y "$SALA_LANES")
for form in "lane" "lane --list" "lane --json" "lane bogus sala-test-c" "lane default bogus" "lane default bedrock --dry-run" "lane bedrock sala-test-a" "lane aws-platform sala-test-a"; do "$SALA" $form >/dev/null 2>&1; done
[ "$(md5sum < "$SALA_LANES")" = "$sum0" ] && [ "$(stat -c %Y.%y "$SALA_LANES")" = "$mt0" ] && ok "the table, --list, --json and five refusals (bogus, default bogus, default bedrock, bedrock, aws-platform): lanes.tsv byte for byte, mtime too" || bad "lanes.tsv changed: $(<"$SALA_LANES")"
[ "$(lane_row sala-test-b)" = sdk ] && [ "$(lane_row sala-test-c)" = bogus ] && ok "the sdk row and the unknown-word row are read as recorded" || bad "rows: $(<"$SALA_LANES")"
[ "$(lane_for_session sala-test-b)" = sdk ] && ok "an sdk row still launches on sdk (inside its window; the sdk suites cover the window)" || bad "sdk row: $(lane_for_session sala-test-b)"
[ "$(lane_for_session sala-test-c)" = subscription-1 ] && ok "an unknown-word row launches on the default (subscription-1)" || bad "unknown row: $(lane_for_session sala-test-c)"
out=$("$SALA" lane 2>&1)
grep -qE "^sala-test-c  *bogus .*the recorded lane 'bogus' is not a lane" <<< "$out" && ok "sala lane flags the unknown-word row under SESSION, and says the row is left as it is" || bad "unknown row not flagged: $out"
[ "$(grep -c '⚠ the recorded lane' <<< "$out")" = 1 ] && ok "only that row is flagged (subscription-1, sdk, subscription-2 are fine)" || bad "flags: $(grep '⚠ the recorded' <<< "$out")"
[ "$(md5sum < "$SALA_LANES")" = "$sum0" ] && ok "flagging rewrote nothing" || bad "lanes.tsv changed by the table"
lane_write sala-test-e api; lane_write sala-test-a subscription-2
bad_rows=$(awk -F'\t' 'NF != 2 || $1 == "" || $2 !~ /^[a-z0-9-]+$/' "$SALA_LANES" | wc -l); [ "$bad_rows" = 0 ] && ok "a written row is still '<session>TAB<lane>', two fields, one per line" || bad "format: $(cat -A "$SALA_LANES")"
[ "$(lane_row sala-test-c)" = bogus ] && [ "$(lane_row sala-test-b)" = sdk ] && ok "a write for other sessions leaves the unknown-word and sdk rows alone" || bad "rows after a write: $(<"$SALA_LANES")"
printf 'bogus\n' > "$SALA_LANE_DEFAULT_FILE"; [ "$(lane_default)" = subscription-1 ] && ok "a default file saying an unknown word reads as subscription-1 (the unknown-word fallback), the file untouched" || bad "default: $(lane_default)"; [ "$(<"$SALA_LANE_DEFAULT_FILE")" = bogus ] || bad "default file rewritten"

echo "== the registry, the web app and the docs"
for f in README.md config.example; do grep -q 'THE LANE FIELDS\|Lane fields\|lane --list' "$ROOT/$f" && ok "$f documents the lane fields" || bad "$f does not mention the lane fields"; done

[ "$fail" = 0 ] && echo "lanefields: pass" || echo "lanefields: FAIL"
exit $fail
