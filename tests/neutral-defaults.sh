#!/usr/bin/env bash
# Neutral defaults: a sala installed on another person's machine shows none of the first owner's values. Every value that used to be a
# code default and named a person, an organization, an account, an AWS profile or a web address is a setting whose default is empty or
# neutral, and a config line restores any of them. Checked here with no config (SALA_CONFIG at an empty file) and with a config of
# made-up values (example.com, alice, example-org, t-host-a):
#   SALA_JOB_LANE subscription-1; SALA_SETTINGS_APPLY off; the bedrock and aws-platform lanes say the AWS profile is not set (lane_check), and
#   name it in `lane --list`'s help line; the lane field table reads unconfirmed (accounts, orgs) and names no person or company;
#   SALA_SESSION_URL, SALA_STACKSHOT_WEB empty (no web link; a side session's mandate says how to read the item instead); the CI
#   poller and the unit jobs name no GitHub owner or repo; the tracked lists (lib/ci-repos, lib/unit-repos.tsv) hold only comments;
#   no tracked default names the first owner's domain; each setting is documented in config.example.
#   SALA_SHELL_SESSION defaults to sala-shell (the web app reads the same line); SALA_TZ unset is this machine's local time in every
#   time sala shows (set, that zone, the label its own); SALA_BACK_CWD unset names no directory (a background agent starts in $HOME).
#   SALA_SCOPES, SALA_DEFAULT_SCOPE and SALA_BRAND_SUFFIX are empty (no scope, "salamander" alone in the web title bar); spawn's page-name
#   prefix is <scope>-<slug> from them (the slug alone with none set).
#   SALA_OWNER_NAME defaults to "the owner" (empty counts as unset), is exported to Python, and a config line restores a made-up name;
#   no runtime string in lib/, bin/, web/src/, mod/ or contrib/ (briefing aside) names the first owner: a scan of the shipped files
#   leaves out comments and docstrings, and a planted line proves the scan finds one. The documented literals (the older spelling of the owner kind in a provision step line,
#   stackshot's mover kind) are lower case, which the scan does not look for.
# The first owner's private values (names, domain, machines, profiles) are in no suite: the checks for them read the deny source clean_text.py reads
# ($CLEAN_TEXT_DENY, else ~/.config/salamander/clean-text-deny; tests/deny_source.py), print counts and line numbers only, and skip with a notice where there is none.
# Isolated HOME in a temp folder (locked while the suite runs, removed at the end), no tmux, nothing real.
# Usage: bash tests/neutral-defaults.sh   (exit 0 = pass; a few seconds)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
T=""
trap '[ -n "$T" ] && rm -rf "$T"' EXIT
T=$(mktemp -d "${TMPDIR:-/tmp}/sala-neutral.XXXXXX")
exec 8< "$T"; flock -n 8 2>/dev/null   # systemd-tmpfiles' ageing skips a directory held with flock
deny_load "$T/deny"   # the owner's private values come from the deny source at run time, never from this file (read before HOME changes)
export HOME="$T/home"; mkdir -p "$HOME/.claude" "$HOME/.config/salamander"
# tests/lib.sh gives the other suites a fixture profile and job lane; this one starts from a bare environment
unset SALA_UNIT_PROJECT_MAP SALA_OWNER_NAME SALA_TZ SALA_SHELL_SESSION SALA_BACK_CWD SALA_SCOPES SALA_DEFAULT_SCOPE SALA_BRAND_SUFFIX SALA_HELP_SESSION SALA_JOB_LANE SALA_SETTINGS_APPLY SALA_SESSION_URL SALA_STACKSHOT_WEB SALA_JOB_GITHUB SALA_FLEET_HOSTS SALA_MASTER XDG_CONFIG_HOME XDG_STATE_HOME TMUX TMUX_PANE
for v in $(compgen -v | grep -E '^SALA_LANE_'); do unset "$v"; done
EMPTY="$T/empty-config"; : > "$EMPTY"

# sh_in <config file> '<script>' — the script runs in a fresh bash that sources lib/common.sh (and settings-apply.sh) under that config
sh_in() { SALA_CONFIG="$1" SALA_ROOT="$ROOT" bash -c '. "$SALA_ROOT/lib/common.sh"; . "$SALA_ROOT/lib/settings-apply.sh"; '"$2" 2>&1; }

echo "== no config: the neutral defaults"
[ "$(sh_in "$EMPTY" 'echo "$SALA_JOB_LANE"')" = subscription-1 ] && ok "SALA_JOB_LANE defaults to subscription-1" || bad "job lane: $(sh_in "$EMPTY" 'echo "$SALA_JOB_LANE"')"
[ "$(sh_in "$EMPTY" 'echo "$SALA_SETTINGS_APPLY"')" = off ] && ok "SALA_SETTINGS_APPLY defaults to off" || bad "settings apply: $(sh_in "$EMPTY" 'echo "$SALA_SETTINGS_APPLY"')"
sh_in "$EMPTY" 'sa_on' >/dev/null && bad "sa_on is true with no config" || ok "sa_on is false with no config"
out=$(sh_in "$EMPTY" 'sa_status 2>&1 | head -1'); case "$out" in "settings apply: off"*) ok "settings-apply's status says off";; *) bad "status: $out";; esac
for v in SALA_LANE_BEDROCK_PROFILE SALA_LANE_AWSPLATFORM_PROFILE SALA_LANE_BEDROCK_REGION SALA_LANE_AWSPLATFORM_REGION SALA_LANE_TEAM_ORG SALA_LANE_MAX_ORG SALA_STACKSHOT_WEB SALA_SESSION_URL_DEFAULT; do
    [ -z "$(sh_in "$EMPTY" "printf %s \"\${$v:-}\"")" ] && ok "$v is empty by default" || bad "$v: $(sh_in "$EMPTY" "printf %s \"\${$v:-}\"")"
done
out=$(sh_in "$EMPTY" 'lane_check bedrock; echo "rc=$?"')
case "$out" in *"bedrock lane: the AWS profile is not set"*"SALA_LANE_BEDROCK_PROFILE"*"rc=1") ok "lane_check bedrock: the AWS profile is not set, names the setting";; *) bad "bedrock: $out";; esac
out=$(sh_in "$EMPTY" 'lane_check aws-platform; echo "rc=$?"')
case "$out" in *"aws-platform lane: the AWS profile is not set"*"SALA_LANE_AWSPLATFORM_PROFILE"*"rc=1") ok "lane_check aws-platform: the AWS profile is not set, names the setting";; *) bad "aws-platform: $out";; esac
[ "$(sh_in "$EMPTY" 'session_url_template; echo x')" = x ] && ok "no session link template without SALA_SESSION_URL, even on a box that names fleet hosts" || bad "template: $(sh_in "$EMPTY" 'session_url_template; echo x')"
[ "$(SALA_FLEET_HOSTS=t-host-a sh_in "$EMPTY" 'session_url_template; echo x')" = x ] && ok "with SALA_FLEET_HOSTS set it is still empty" || bad "template with fleet hosts"
[ "$(sh_in "$EMPTY" 'session_url alice')" = "" ] && ok "an unbridged session has no link" || bad "link: $(sh_in "$EMPTY" 'session_url alice')"
[ "$(sh_in "$EMPTY" 'session_url alice bridge_01Abc')" = "https://claude.ai/code/session_01Abc" ] && ok "a bridged session gets the claude.ai link" || bad "bridge link: $(sh_in "$EMPTY" 'session_url alice bridge_01Abc')"

# the region has no default either: with a profile (and for aws-platform a workspace id) present, the missing region is what the lane names
printf '[%s]\n' fixture > "$HOME/.aws-fixture-credentials"
out=$(SALA_LANE_BEDROCK_PROFILE=fixture SALA_LANE_BEDROCK_CREDENTIALS_FILE="$HOME/.aws-fixture-credentials" sh_in "$EMPTY" 'lane_check bedrock; echo "rc=$?"; lane_field bedrock region; echo "status=$(lane_field bedrock status)"')
case "$out" in *"bedrock lane: the AWS region is not set"*"SALA_LANE_BEDROCK_REGION"*"rc=1"*"status=not set up") ok "lane_check bedrock: the AWS region is not set, names the setting; no region field";; *) bad "bedrock region: $out";; esac
out=$(SALA_LANE_AWSPLATFORM_PROFILE=fixture SALA_LANE_AWSPLATFORM_WORKSPACE_ID=wrkspc_01EXAMPLE SALA_LANE_AWSPLATFORM_CREDENTIALS_FILE="$HOME/.aws-fixture-credentials" sh_in "$EMPTY" 'lane_check aws-platform; echo "rc=$?"; lane_field aws-platform region; echo "status=$(lane_field aws-platform status)"')
case "$out" in *"aws-platform lane: the AWS region is not set"*"SALA_LANE_AWSPLATFORM_REGION"*"rc=1"*"status=not set up") ok "lane_check aws-platform: the AWS region is not set, names the setting; no region field";; *) bad "aws-platform region: $out";; esac

echo "== no config: the lane fields name nobody"
names=$(sh_in "$EMPTY" 'for l in $SALA_LANES_DEFINED; do for f in $SALA_LANE_FIELDS; do printf "%s:%s=%s\n" "$l" "$f" "$(lane_field $l $f)"; done; done')
echo "$names" | grep -qF -- '@' && bad "the lane table names an address: $(echo "$names" | grep -F -- '@' | head -3 | tr '\n' ' ')" || ok "the lane table has no '@'"
if deny_have; then
    n=$(echo "$names" | deny_count); [ "$n" = 0 ] && ok "the lane table has no deny-source hit" || bad "the lane table hits the deny source on $n line(s)"
fi
for kv in subscription-1:org=unconfirmed subscription-1:account=unconfirmed subscription-2:org=unconfirmed subscription-2:account=unconfirmed api:org=unconfirmed 'bedrock:org=AWS account' bedrock:account=unconfirmed aws-platform:account=unconfirmed; do
    echo "$names" | grep -qxF -- "$kv" && ok "$kv" || bad "expected $kv"
done

echo "== no config: the shell session name, the time zone and the background directory"
[ "$(sh_in "$EMPTY" 'echo "$SALA_SHELL_SESSION"')" = sala-shell ] && ok "SALA_SHELL_SESSION defaults to sala-shell" || bad "shell session: $(sh_in "$EMPTY" 'echo "$SALA_SHELL_SESSION"')"
sh_in "$EMPTY" 'is_shell_session sala-shell' >/dev/null && ok "is_shell_session knows the default name" || bad "is_shell_session sala-shell"
sh_in "$EMPTY" 'is_shell_session some-shell' >/dev/null && bad "is_shell_session accepts another name" || ok "is_shell_session refuses another name"
[ -z "$(sh_in "$EMPTY" 'printf %s "$SALA_TZ"')" ] && ok "SALA_TZ is empty by default" || bad "SALA_TZ: $(sh_in "$EMPTY" 'printf %s "$SALA_TZ"')"
[ -z "$(sh_in "$EMPTY" 'printf %s "${SALA_BACK_CWD:-}"')" ] && ok "SALA_BACK_CWD is empty by default" || bad "SALA_BACK_CWD: $(sh_in "$EMPTY" 'printf %s "${SALA_BACK_CWD:-}"')"
# a made-up machine zone (no relation to the owner's): with SALA_TZ unset every time follows it, as `date` does
E=1790000000   # Sep 21st 2026, 14:13:20 UTC
for z in America/Los_Angeles Asia/Kolkata Etc/UTC; do
    out=$(TZ=$z sh_in "$EMPTY" "_when_r w $E; echo \"\$w\"")
    kh=$(TZ=$z sh_in "$EMPTY" "local_human $E")
    case "$kh" in "$(TZ=$z command date -d "@$E" '+%H:%M %Z %a %b')"*) ok "SALA_TZ unset, machine zone $z: local_human gives its own clock and label ($kh)";; *) bad "local_human in $z: $kh";; esac
    [ "$(TZ=$z sh_in "$EMPTY" "_when_r w $E; echo \"\$w\"" | awk '{print $NF}')" = "$(TZ=$z command date -d "@$E" '+%H:%M')" ] && ok "SALA_TZ unset, machine zone $z: _when_r gives the machine's time" || bad "_when_r in $z: $(TZ=$z sh_in "$EMPTY" "_when_r w $E; echo \"\$w\"")"
    [ "$(TZ=$z sh_in "$EMPTY" 'cs_tzlabel')" = "$(TZ=$z command date '+%Z')" ] && ok "SALA_TZ unset, machine zone $z: cs_tzlabel is the machine's label" || bad "cs_tzlabel in $z"
done
# lane_day: 2026-09-21T23:30:00Z is Sep 22nd in Asia/Kolkata and Sep 21st in America/Los_Angeles
[ "$(TZ=Asia/Kolkata sh_in "$EMPTY" 'lane_day 2026-09-21T23:30:00Z')" = "Tue Sep 22nd" ] && ok "SALA_TZ unset: lane_day follows the machine zone (Asia/Kolkata)" || bad "lane_day Kolkata: $(TZ=Asia/Kolkata sh_in "$EMPTY" 'lane_day 2026-09-21T23:30:00Z')"
[ "$(TZ=America/Los_Angeles sh_in "$EMPTY" 'lane_day 2026-09-21T23:30:00Z')" = "Mon Sep 21st" ] && ok "SALA_TZ unset: lane_day follows the machine zone (America/Los_Angeles)" || bad "lane_day LA: $(TZ=America/Los_Angeles sh_in "$EMPTY" 'lane_day 2026-09-21T23:30:00Z')"
# SALA_TZ set wins over the machine zone, and the label is the zone's own; Asia/Kolkata keeps its output exactly
printf 'SALA_TZ=Asia/Kolkata\n' > "$T/config-tz"
[ "$(TZ=America/Los_Angeles sh_in "$T/config-tz" 'local_human 1790000000')" = "19:43 IST Mon Sep 21st" ] && ok "SALA_TZ=Asia/Kolkata: local_human reads 19:43 IST whatever the machine zone" || bad "local_human Kolkata: $(TZ=America/Los_Angeles sh_in "$T/config-tz" 'local_human 1790000000')"
[ "$(TZ=America/Los_Angeles sh_in "$T/config-tz" 'lane_day 2026-09-21T23:30:00Z')" = "Tue Sep 22nd" ] && ok "SALA_TZ=Asia/Kolkata: lane_day gives the Kolkata day" || bad "lane_day Kolkata: $(TZ=America/Los_Angeles sh_in "$T/config-tz" 'lane_day 2026-09-21T23:30:00Z')"
[ "$(TZ=America/Los_Angeles sh_in "$T/config-tz" '_when_r w 1790000000; echo "$w"')" = "$(TZ=Asia/Kolkata command date -d @1790000000 '+%a %b %-dst %H:%M')" ] && ok "SALA_TZ=Asia/Kolkata: _when_r matches date in that zone" || bad "_when_r Kolkata: $(TZ=America/Los_Angeles sh_in "$T/config-tz" '_when_r w 1790000000; echo "$w"')"
printf 'SALA_TZ=Europe/Berlin\nSALA_SHELL_SESSION=my-console\n' > "$T/config-b"
[ "$(sh_in "$T/config-b" 'local_human 1790000000')" = "16:13 CEST Mon Sep 21st" ] && ok "SALA_TZ=Europe/Berlin: another zone gives its own label (CEST), no fixed label" || bad "local_human Berlin: $(sh_in "$T/config-b" 'local_human 1790000000')"
[ "$(sh_in "$T/config-b" 'echo "$SALA_SHELL_SESSION"')" = my-console ] && ok "SALA_SHELL_SESSION=my-console in the config wins" || bad "shell session from config"
sh_in "$T/config-b" 'is_shell_session my-console' >/dev/null && ok "is_shell_session follows the setting" || bad "is_shell_session my-console"
printf 'SALA_SHELL_SESSION=alex-shell\nSALA_BACK_CWD=%s/briefs\n' "$HOME" > "$T/config-keep"
[ "$(sh_in "$T/config-keep" 'echo "$SALA_SHELL_SESSION $SALA_BACK_CWD"')" = "alex-shell $HOME/briefs" ] && ok "a config line keeps a previous owner's session name and background directory" || bad "kept names: $(sh_in "$T/config-keep" 'echo "$SALA_SHELL_SESSION $SALA_BACK_CWD"')"
out=$(sh_in "$EMPTY" 'cs_print_config 2>&1')
for kv in 'SALA_SHELL_SESSION +sala-shell$' 'SALA_TZ *$' 'SALA_BACK_CWD *$'; do
    echo "$out" | grep -qE -- "^$kv" && ok "config print lists ${kv%% *}" || bad "config print misses '$kv'"
done

echo "== scopes and the title bar's name: none built in, a config line sets them"
for v in SALA_SCOPES SALA_DEFAULT_SCOPE SALA_BRAND_SUFFIX; do
    [ -z "$(sh_in "$EMPTY" "printf %s \"\${$v:-}\"")" ] && ok "$v is empty by default" || bad "$v: $(sh_in "$EMPTY" "printf %s \"\${$v:-}\"")"
done
out=$(sh_in "$EMPTY" 'cs_print_config 2>&1')
for v in SALA_SCOPES SALA_DEFAULT_SCOPE SALA_BRAND_SUFFIX; do
    echo "$out" | grep -qE -- "^$v( |$)" && ok "config print lists $v" || bad "config print misses $v"
done
# suggest_prefix alone, the way the mandate test above takes one function out of lib/spawn.sh
pfx() { SALA_CONFIG="$1" SALA_ROOT="$ROOT" bash -c '. "$SALA_ROOT/lib/common.sh"; eval "$(sed -n "/^suggest_prefix() {/,/^}/p" "$SALA_ROOT/lib/spawn.sh")"; suggest_prefix "$1"' _ "$2" 2>&1; }
printf 'SALA_SCOPES="work home"\n' > "$T/config-scopes"
printf 'SALA_SCOPES="work home"\nSALA_DEFAULT_SCOPE=home\n' > "$T/config-scopes-default"
[ "$(pfx "$EMPTY" projects/garden)" = garden ] && [ "$(pfx "$EMPTY" work/garden)" = garden ] && ok "no scopes: the page-name prefix is the slug alone, whatever the directory" || bad "no scopes: $(pfx "$EMPTY" projects/garden) $(pfx "$EMPTY" work/garden)"
[ "$(pfx "$T/config-scopes" projects/garden)" = work-garden ] && ok "SALA_SCOPES alone: a page in no scope's directory is named in the first scope" || bad "first scope: $(pfx "$T/config-scopes" projects/garden)"
[ "$(pfx "$T/config-scopes-default" projects/garden)" = home-garden ] && ok "SALA_DEFAULT_SCOPE: a page in no scope's directory is named in it" || bad "default scope: $(pfx "$T/config-scopes-default" projects/garden)"
[ "$(pfx "$T/config-scopes-default" work/ledger)" = work-ledger ] && ok "a page whose directory is a scope is named in that scope" || bad "dir scope: $(pfx "$T/config-scopes-default" work/ledger)"
printf 'SALA_SCOPES="work home lab"\nSALA_DEFAULT_SCOPE=home\n' > "$T/config-scopes-three"
[ "$(pfx "$T/config-scopes-default" projects/work-ledger)" = work-ledger ] && [ "$(pfx "$T/config-scopes-three" projects/lab-ledger)" = lab-ledger ] && ok "a slug that already leads with another scope is the prefix as it is" || bad "slug scope: $(pfx "$T/config-scopes-default" projects/work-ledger) $(pfx "$T/config-scopes-three" projects/lab-ledger)"
[ "$(pfx "$T/config-scopes-three" lab/work-x)" = lab-work-x ] && [ "$(pfx "$T/config-scopes-default" work/work-ledger)" = work-work-ledger ] && ok "the page's directory is tested before the slug: lab/work-x is lab-work-x, work/work-ledger is work-work-ledger" || bad "dir before slug: $(pfx "$T/config-scopes-three" lab/work-x) $(pfx "$T/config-scopes-default" work/work-ledger)"
[ "$(pfx "$T/config-scopes-default" projects/home-ledger)" = home-home-ledger ] && ok "the default scope is always put in front, even before a slug that leads with it" || bad "default doubling: $(pfx "$T/config-scopes-default" projects/home-ledger)"
[ "$(pfx "$T/config-scopes-three" projects/work)" = home-work ] && ok "a slug equal to a scope's name (no dash after it) is not a scope's page" || bad "slug equals scope: $(pfx "$T/config-scopes-three" projects/work)"
printf 'SALA_SCOPES="work *"\nSALA_DEFAULT_SCOPE=work\n' > "$T/config-scopes-glob"
( cd "$T" && [ "$(pfx "$T/config-scopes-glob" projects/garden)" = work-garden ] && [ "$(pfx "$T/config-scopes-glob" config-scopes/x)" = work-x ] ) && ok "a glob in SALA_SCOPES is not expanded against the files in the directory" || bad "glob: $(cd "$T" && pfx "$T/config-scopes-glob" config-scopes/x)"
[ "$(pfx "$T/config-scopes-default" projects/workshop)" = home-workshop ] && ok "a slug that only starts with a scope's letters is not in that scope" || bad "workshop: $(pfx "$T/config-scopes-default" projects/workshop)"
printf 'SALA_BRAND_SUFFIX="example fleet"\n' > "$T/config-brand"
[ "$(sh_in "$T/config-brand" 'echo "$SALA_BRAND_SUFFIX"')" = "example fleet" ] && ok "SALA_BRAND_SUFFIX in the config is read" || bad "brand: $(sh_in "$T/config-brand" 'echo "$SALA_BRAND_SUFFIX"')"

echo "== the owner's name in runtime text: neutral by default, a config line sets it"
[ "$(sh_in "$EMPTY" 'echo "$SALA_OWNER_NAME"')" = "the owner" ] && ok "SALA_OWNER_NAME defaults to 'the owner'" || bad "owner name: $(sh_in "$EMPTY" 'echo "$SALA_OWNER_NAME"')"
[ "$(SALA_OWNER_NAME= sh_in "$EMPTY" 'echo "$SALA_OWNER_NAME"')" = "the owner" ] && ok "set empty it is the default too" || bad "empty owner name"
sh_in "$EMPTY" 'cs_print_config 2>&1' | grep -qE -- '^SALA_OWNER_NAME( |$)' && ok "config print lists SALA_OWNER_NAME" || bad "config print misses SALA_OWNER_NAME"
printf 'SALA_OWNER_NAME="Sam Example"\n' > "$T/config-owner"
[ "$(sh_in "$T/config-owner" 'echo "$SALA_OWNER_NAME"')" = "Sam Example" ] && ok "SALA_OWNER_NAME in the config is read" || bad "owner name with config: $(sh_in "$T/config-owner" 'echo "$SALA_OWNER_NAME"')"
[ "$(sh_in "$T/config-owner" 'python3 -I -S -c "import os; print(os.environ.get(\"SALA_OWNER_NAME\", \"unset\"))"')" = "Sam Example" ] && ok "common.sh exports it, so a Python helper reads the same name" || bad "owner name not exported"
out=$(sh_in "$EMPTY" 'echo "$SALA_FALLBACK_WORDS"')
if deny_have && [ "$(echo "$out" | deny_count)" != 0 ]; then bad "the fallback words hit the deny source"; else case "$out" in "the owner's standing pick"*"until the owner or a session moves them back."*) ok "SALA_FALLBACK_WORDS reads naturally with the neutral default";; *) bad "fallback words: $out";; esac; fi
out=$(sh_in "$T/config-owner" 'echo "$SALA_FALLBACK_WORDS"'); case "$out" in "Sam Example's standing pick"*"until Sam Example or a session moves them back."*) ok "and follows the setting";; *) bad "fallback words with a name: $out";; esac
if deny_have; then n=$(deny_count "$ROOT/tests/help-snapshot.txt"); [ "$n" = 0 ] && ok "no help text hits the deny source" || bad "the help snapshot hits the deny source on $n line(s): $(deny_at "$ROOT/tests/help-snapshot.txt")"; fi
# the scan: every shipped runtime string, not a comment or a docstring (tracked files only, so a stray local file is not read)
cat > "$T/runtime_scan.py" <<'PYEOF'
import ast, io, os, re, subprocess, sys, tokenize

root = sys.argv[1]
sys.path.insert(0, sys.argv[2])   # tests/, for deny_source
import deny_source
NAME = deny_source.Deny(sys.argv[3])   # the deny rules (a file in the suite's temp folder): NAME.search(text) is a match or None
files = subprocess.run(["git", "-C", root, "ls-files", "lib", "bin", "web/src", "mod", "contrib"],
                       capture_output=True, text=True, check=True).stdout.split("\n")
files = [f for f in files if f and not f.startswith("contrib/briefing/") and not os.path.basename(f).startswith(".")
         and not f.endswith((".png", ".webmanifest", ".json", ".md", ".woff", ".woff2", ".ico", ".svg", ".tsv"))]


def sh_like(text):
    # lines of a shell script: a whole-line comment and a trailing ' # …' comment are not runtime text
    for n, line in enumerate(text.split("\n"), 1):
        if re.match(r"\s*#", line):
            continue
        m = NAME.search(line)
        if not m:
            continue
        if re.search(r"(^|\s)#", line[:m.start()]):
            continue
        yield n, line


def py_like(text):
    tree = ast.parse(text)
    skip = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)) and node.body:
            b = node.body[0]
            if isinstance(b, ast.Expr) and isinstance(b.value, ast.Constant) and isinstance(b.value.value, str):
                skip.update(range(b.lineno, b.end_lineno + 1))
    lines = text.split("\n")
    seen = set()
    for tok in tokenize.generate_tokens(io.StringIO(text).readline):
        name = tokenize.tok_name[tok.type]
        if name in ("STRING", "FSTRING_MIDDLE") and NAME.search(tok.string):
            for ln in range(tok.start[0], tok.end[0] + 1):
                if ln in skip or ln in seen:
                    continue
                if NAME.search(lines[ln - 1]):
                    seen.add(ln)
                    yield ln, lines[ln - 1]


def web_like(text):
    # js / css / html / ts: block comments, html comments and '// …' comments are not runtime text
    text = re.sub(r"/\*.*?\*/", lambda m: re.sub(r"[^\n]", " ", m.group()), text, flags=re.S)
    text = re.sub(r"<!--.*?-->", lambda m: re.sub(r"[^\n]", " ", m.group()), text, flags=re.S)
    for n, line in enumerate(text.split("\n"), 1):
        line = re.sub(r"(^|\s)//.*$", "", line)
        if NAME.search(line):
            yield n, line


hits = []
for f in files:
    p = os.path.join(root, f)
    try:
        text = open(p, encoding="utf-8").read()
    except (UnicodeDecodeError, IsADirectoryError, FileNotFoundError):
        continue
    if f.endswith(".py"):
        it = py_like(text)
    elif f.endswith((".js", ".css", ".html", ".ts")):
        it = web_like(text)
    else:
        it = sh_like(text)
    for n, line in it:
        hits.append("%s:%d:%s" % (f, n, line.strip()[:110]))
print("\n".join(hits))
PYEOF
if deny_have; then
    hits=$(python3 -I "$T/runtime_scan.py" "$ROOT" "$ROOT/tests" "$DENY_FILE" | cut -d: -f1,2)   # file:line only, never the text
    [ -z "$hits" ] && ok "no runtime string in lib/, bin/, web/src/, mod/ or contrib/ hits the deny source" || bad "deny-source hits in runtime text: $(echo "$hits" | head -5 | tr '\n' ' ')"
fi
# the scan itself, on planted lines and a made-up name in a deny file of its own (it needs no real deny source)
mkdir -p "$T/scan/lib"
O="Quillworks"; printf 'quillworks\n' > "$T/deny-plant"; printf '%s\n' "# $O in a comment" "echo \"ok\"   # $O here too" "echo \"$O waits\"" > "$T/scan/lib/a.sh"
printf '%s\n' "\"\"\"$O in a docstring.\"\"\"" "X = \"$O in a string\"" > "$T/scan/lib/b.py"
git -C "$T/scan" init -q && git -C "$T/scan" add lib
hits=$(python3 -I "$T/runtime_scan.py" "$T/scan" "$ROOT/tests" "$T/deny-plant")
[ "$(echo "$hits" | grep -c .)" = 2 ] && echo "$hits" | grep -q 'lib/a.sh:3:' && echo "$hits" | grep -q 'lib/b.py:2:' && ok "the scan finds a planted string and skips a comment and a docstring" || bad "the scan on planted lines: $hits"

echo "== a config of made-up values restores them"
CFG="$T/config"
cat > "$CFG" <<'EOF'
SALA_JOB_LANE=bedrock
SALA_SETTINGS_APPLY=on
SALA_LANE_TEAM_ORG=example-org
SALA_LANE_BEDROCK_PROFILE=example-bedrock
SALA_LANE_AWSPLATFORM_PROFILE=example-bedrock
SALA_LANE_MAX_ACCOUNT=alice@example.com
SALA_LANE_BEDROCK_ORG="AWS account via Example Reseller"
SALA_SESSION_URL='https://sala.example.com/#s={name}'
SALA_STACKSHOT_WEB=https://board.example.com
EOF
[ "$(sh_in "$CFG" 'echo "$SALA_JOB_LANE"')" = bedrock ] && ok "SALA_JOB_LANE=bedrock in the config wins" || bad "job lane with config"
sh_in "$CFG" 'sa_on' >/dev/null && ok "SALA_SETTINGS_APPLY=on turns the service on" || bad "sa_on with config"
for v in yes true 1; do SALA_SETTINGS_APPLY=$v sh_in "$EMPTY" 'sa_on' >/dev/null && ok "SALA_SETTINGS_APPLY=$v is on too" || bad "sa_on for $v"; done
for v in ON Yes TRUE; do SALA_SETTINGS_APPLY=$v sh_in "$EMPTY" 'sa_on' >/dev/null && ok "SALA_SETTINGS_APPLY=$v is on too (case does not matter)" || bad "sa_on for $v"; done
for v in off no 0 maybe; do SALA_SETTINGS_APPLY=$v sh_in "$EMPTY" 'sa_on' >/dev/null && bad "SALA_SETTINGS_APPLY=$v counted as on" || ok "SALA_SETTINGS_APPLY=$v stays off"; done
[ "$(sh_in "$CFG" 'echo "$SALA_LANE_TEAM_ORG"')" = example-org ] && ok "SALA_LANE_TEAM_ORG from the config (the sign-in watch's expected organization)" || bad "team org"
[ "$(sh_in "$CFG" 'lane_field subscription-1 account; lane_field subscription-1 org; lane_field bedrock org; lane_field subscription-2 org')" = $'alice@example.com\nalice@example.com\'s Organization\nAWS account via Example Reseller\nexample-org' ] \
    && ok "the lane fields follow the config (a subscription-1 account names the org; a bedrock org is replaced; subscription-2 org shows the watch's expected organization)" || bad "fields: $(sh_in "$CFG" 'lane_field subscription-1 account; lane_field subscription-1 org; lane_field bedrock org; lane_field subscription-2 org')"
printf '[example-bedrock]\naws_access_key_id = x\n' > "$T/creds"   # only the header line is looked for
out=$(SALA_LANE_BEDROCK_CREDENTIALS_FILE="$T/creds" sh_in "$CFG" 'lane_check bedrock; echo "rc=$?"')
case "$out" in *"profile is not set"*) bad "bedrock with the profile named still says it is not set: $out";; *) ok "bedrock with the profile named: no longer 'not set' (${out##*$'\n'})";; esac
[ "$(sh_in "$CFG" 'session_url_template')" = 'https://sala.example.com/#s={name}' ] && ok "SALA_SESSION_URL from the config is the template" || bad "template with config"
[ "$(sh_in "$CFG" 'session_url alice')" = 'https://sala.example.com/#s=alice' ] && ok "the session link uses it" || bad "link with config: $(sh_in "$CFG" 'session_url alice')"
[ "$(SALA_SESSION_URL= sh_in "$EMPTY" 'session_url alice bridge_01Abc')" = "https://claude.ai/code/session_01Abc" ] && ok "SALA_SESSION_URL set empty is the claude.ai link too" || bad "empty template"

echo "== a side session's mandate: the board link only when the address is set"
eval "$(sed -n '/^side_write_mandate() {/,/^}/p' "$ROOT/lib/spawn.sh")"
_mkparent() { mkdir -p "$(dirname "$1")"; }
SALA_OWNER_NAME="the owner"   # this shell never sourced common.sh, which sets it for the function above
ITEM="board#12" SIDE_KIND=discuss NAME=alice-side FORK_OF="" SIDE_PROJECT=projects/example SIDE_TO=alice-main AGENTS="" MFILE="" MTEXT=""
SIDE_MFILE="$T/mandate-a.md"; SALA_STACKSHOT_WEB="" side_write_mandate
grep -q 'read it with the stackshot connector' "$SIDE_MFILE" && ! grep -q 'http' "$SIDE_MFILE" && ok "no SALA_STACKSHOT_WEB: the mandate names the id and says how to read it, no web link" || bad "mandate without address: $(grep -n 'board#12' "$SIDE_MFILE")"
SIDE_MFILE="$T/mandate-b.md"; SALA_STACKSHOT_WEB="https://board.example.com/" side_write_mandate
grep -q '(https://board.example.com/items/12)' "$SIDE_MFILE" && ok "SALA_STACKSHOT_WEB set: the mandate links <address>/items/12" || bad "mandate with address: $(grep -n 'board#12' "$SIDE_MFILE")"

echo "== the CI poller and the unit jobs name no owner"
R="$ROOT/lib/ci-repos"
[ -z "$(grep -vE '^[[:space:]]*(#|$)' "$R")" ] && ok "lib/ci-repos holds comments only" || bad "lib/ci-repos names: $(grep -vE '^[[:space:]]*(#|$)' "$R")"
U="$ROOT/lib/unit-repos.tsv"
[ -z "$(grep -vE '^[[:space:]]*(#|$)' "$U")" ] && ok "lib/unit-repos.tsv holds comments only" || bad "lib/unit-repos.tsv names: $(grep -vE '^[[:space:]]*(#|$)' "$U")"
out=$(env -u SALA_CIPOLL_REPOS HOME="$HOME" SALA_CIPOLL_CYCLES=1 SALA_CIPOLL_INTERVAL=0.1 SALA_CIRUNS_DIR="$T/runs" PATH="$PATH" bash "$ROOT/bin/salamander" ci-poll 2>&1)
case "$out" in *"names no repo"*) ok "ci-poll with no list says so and polls nothing";; *) bad "ci-poll: $out";; esac
[ -z "$(ls "$T/runs" 2>/dev/null)" ] && ok "and writes no file" || bad "files: $(ls "$T/runs")"
[ "$(env -u SALA_JOB_GITHUB python3 -I -S -c 'import sys; sys.path.insert(0, sys.argv[1]); import unitjob; print(repr(unitjob.GITHUB_DEFAULT))' "$ROOT/lib")" = "''" ] && ok "unitjob.GITHUB_DEFAULT is empty without SALA_JOB_GITHUB" || bad "GITHUB_DEFAULT"
[ "$(SALA_JOB_GITHUB=alice/app python3 -I -S -c 'import sys; sys.path.insert(0, sys.argv[1]); import unitjob; print(unitjob.GITHUB_DEFAULT)' "$ROOT/lib")" = alice/app ] && ok "SALA_JOB_GITHUB=alice/app is read" || bad "GITHUB_DEFAULT with setting"

echo "== the tracked defaults carry no owner address, and every setting is documented"
if deny_have; then
    # the owner's web address, AWS profile, account, session and machine names are the deny source's lines, never written here; only file names are printed
    hits=$(cd "$ROOT" && grep -rIl --exclude-dir=.git --exclude-dir=tests --exclude-dir=node_modules --exclude-dir=.venv --exclude-dir=docs --exclude=README.md --exclude=CONTRIBUTING.md --exclude=clean_text.py -e '' lib bin systemd .github config.example install.sh 2>/dev/null | sort | deny_files)
    hits2=$(cd "$ROOT" && grep -rIl --exclude-dir=.git --exclude-dir=tests --exclude-dir=node_modules --exclude-dir=.venv -e '' lib bin systemd web/src web/contrib config.example install.sh README.md docs/overview.md docs/install.md docs/subcommands.md docs/design-notes.md docs/notices-and-hooks.md docs/recycle.md docs/lanes.md docs/models.md docs/heartbeat-store.md docs/running-without-stackshot.md docs/setup-notes.md web/README.md 2>/dev/null | sort | deny_files)
    [ -z "$hits2" ] && ok "no deny-source hit in the code, units, docs or config.example" || bad "deny-source hits in: $(echo $hits2)"
    [ -z "$hits" ] && ok "no deny-source hit (owner web address, AWS profile, machine or session name) in lib/, bin/, systemd/, .github/, config.example, install.sh" || bad "deny-source hits in: $(echo $hits)"
    # README.md, the docs pages the README's old sections moved to, and config.example name no owner: no owner address, no AWS profile, account, org or reseller
    for f in README.md docs/overview.md docs/install.md docs/subcommands.md docs/design-notes.md docs/notices-and-hooks.md docs/recycle.md docs/lanes.md docs/models.md docs/heartbeat-store.md docs/running-without-stackshot.md docs/setup-notes.md config.example; do
        n=$(deny_count "$ROOT/$f"); [ "$n" = 0 ] && ok "$f has no deny-source hit" || bad "$f has $n deny-source hit lines: $(deny_at "$ROOT/$f")"
    done
fi
for s in SALA_JOB_LANE SALA_SETTINGS_APPLY SALA_JOB_GITHUB SALA_UNIT_PROJECT_MAP SALA_STACKSHOT_WEB SALA_SESSION_URL SALA_SHELL_SESSION SALA_TZ SALA_BACK_CWD SALA_SCOPES SALA_DEFAULT_SCOPE SALA_BRAND_SUFFIX SALA_HELP_SESSION SALA_OWNER_NAME SALA_LANE_BEDROCK_PROFILE SALA_LANE_AWSPLATFORM_PROFILE SALA_LANE_TEAM_ORG ci-repos unit-repos.tsv; do
    grep -q -- "$s" "$ROOT/config.example" && ok "config.example documents $s" || bad "config.example does not mention $s"
done
# the README keeps no settings: its old Lanes section is docs/lanes.md and the section with SALA_OWNER_NAME is docs/recycle.md
grep -q -- SALA_LANE_BEDROCK_PROFILE "$ROOT/docs/lanes.md" && grep -q -- SALA_LANE_TEAM_ORG "$ROOT/docs/lanes.md" && ok "docs/lanes.md documents the profile and organization settings" || bad "docs/lanes.md misses the profile or organization setting"
grep -q -- SALA_OWNER_NAME "$ROOT/docs/recycle.md" && ok "docs/recycle.md documents SALA_OWNER_NAME" || bad "docs/recycle.md does not mention SALA_OWNER_NAME"

echo "== the owner's name is cleaned once, and reaches every helper from the config alone"
# a name with a double quote, a dollar sign, a backtick and a command substitution: common.sh keeps letters, digits, space . _ ' - only
HOSTILE='Eve"; touch '"$T"'/pwn; "$(touch '"$T"'/pwn2)`touch '"$T"'/pwn3` x'
printf 'SALA_OWNER_NAME=%q\n' "$HOSTILE" > "$T/config-hostile"
out=$(sh_in "$T/config-hostile" 'printf %s "$SALA_OWNER_NAME"')
case "$out" in *'"'*|*'$'*|*'`'*|*'\'*|*';'*|*'/'*) bad "the cleaned name still has a shell-active character: $out";; "Eve touch"*) ok "a name with a quote, a dollar sign and a backtick is cleaned once in common.sh";; *) bad "cleaned name: $out";; esac
printf 'SALA_OWNER_NAME=%q\n' '"$()`\' > "$T/config-onlyjunk"
[ "$(sh_in "$T/config-onlyjunk" 'printf %s "$SALA_OWNER_NAME"')" = "the owner" ] && ok "a name that is nothing but shell characters falls back to 'the owner'" || bad "junk-only name: $(sh_in "$T/config-onlyjunk" 'printf %s "$SALA_OWNER_NAME"')"
printf 'SALA_OWNER_NAME=%q\n' "O'Neil-Smith Jr." > "$T/config-apos"
[ "$(sh_in "$T/config-apos" 'printf %s "$SALA_OWNER_NAME"')" = "O'Neil-Smith Jr." ] && ok "letters, space . _ ' - survive the cleaning" || bad "apostrophe name: $(sh_in "$T/config-apos" 'printf %s "$SALA_OWNER_NAME"')"
# provision's PROMPT is re-parsed by the remote shell inside -p "...": expand it under the hostile name, hand it to a second shell the way the ssh line does
out=$(sh_in "$T/config-hostile" 'eval "$(grep -m1 "^PROMPT=" "$SALA_ROOT/lib/provision.sh")"; extra="x"; cmd="printf %s \"$PROMPT $extra\""; r=$(bash -c "$cmd"); [ "$r" = "$PROMPT $extra" ] && echo same || echo "differs: $r"')
[ "$out" = same ] && ok "provision's PROMPT survives the remote shell's second parse under a hostile name" || bad "PROMPT re-parse: $out"
[ ! -e "$T/pwn" ] && [ ! -e "$T/pwn2" ] && [ ! -e "$T/pwn3" ] && ok "and no command in the name ran" || bad "a command in the owner's name ran: $(ls "$T" | grep pwn | tr '\n' ' ')"
# SALA_FALLBACK_WORDS is a default, so the config can override it
printf 'SALA_FALLBACK_WORDS="custom standing pick"\n' > "$T/config-words"
[ "$(sh_in "$T/config-words" 'printf %s "$SALA_FALLBACK_WORDS"')" = "custom standing pick" ] && ok "a SALA_FALLBACK_WORDS line in the config overrides the default" || bad "fallback words override: $(sh_in "$T/config-words" 'printf %s "$SALA_FALLBACK_WORDS"')"
# the Python helpers with the variable unset say 'the owner' (guard.py through its module, question.py through its hook: it runs its mode at import)
out=$(env -u SALA_OWNER_NAME python3 -I -S -c 'import sys; sys.path.insert(0, sys.argv[1]); import guard; print(guard.OWNER)' "$ROOT/lib" 2>&1 | tail -1)
[ "$out" = "the owner" ] && ok "guard.py with SALA_OWNER_NAME unset says 'the owner'" || bad "guard.py unset: $out"
QSTATE="$T/qstate"; mkdir -p "$QSTATE"
QPAY='{"tool_name":"AskUserQuestion","session_id":"s1","tool_use_id":"t1","cwd":"/tmp","tool_input":{"questions":[{"question":"q?"}]}}'
printf '%s' "$QPAY" | env -u SALA_OWNER_NAME -u SALA_BIN SALA_STATE_DIR="$QSTATE" python3 -I -S "$ROOT/lib/question.py" hook >/dev/null 2>&1
QREC=$(ls "$QSTATE"/questions/*/record.json 2>/dev/null | head -1)
python3 -I -S -c 'import json,sys; p=sys.argv[1]; r=json.load(open(p)); r.update(state="answered", decision="deny"); json.dump(r, open(p, "w"))' "$QREC" 2>/dev/null
out=$(printf '%s' "$QPAY" | env -u SALA_OWNER_NAME -u SALA_BIN SALA_STATE_DIR="$QSTATE" python3 -I -S "$ROOT/lib/question.py" hook 2>&1)
case "$out" in *'"The owner declined; nothing was granted"'*) ok "question.py with SALA_OWNER_NAME unset: the reason starts 'The owner declined'";; *) bad "question.py unset: $out";; esac
# provision's post helper (the PYPOST heredoc): a manual step "for the owner" with the variable unset
mkdir -p "$T/prov"; sed -n "/<<'PYPOST'/,/^PYPOST\$/p" "$ROOT/lib/provision.sh" | sed '1d;$d' > "$T/prov/post.py"
printf '#\n' > "$T/prov/words.tsv"
printf 'STEP|manual|apple-id|sign in once|owner\n' > "$T/prov/hostx.steps"; printf 'x' > "$T/prov/hostx.mark"
out=$(env -u SALA_OWNER_NAME python3 -I -S "$T/prov/post.py" "$T/prov" "$T/prov" "$T/prov/words.tsv" hostx 2>&1)
case "$out" in *"left for the owner"*"apple-id"*) ok "provision's post helper with SALA_OWNER_NAME unset says 'left for the owner'";; *) bad "PYPOST unset: $out";; esac
out=$(SALA_OWNER_NAME="Sam Example" python3 -I -S "$T/prov/post.py" "$T/prov" "$T/prov" "$T/prov/words.tsv" hostx 2>&1)
case "$out" in *"left for Sam Example"*"apple-id"*) ok "and with the name set it names it";; *) bad "PYPOST set: $out";; esac
# the pre-tool hook reads the name from the config file when the environment has none (it does not source common.sh)
mkdir -p "$T/hookhome"; printf 'SALA_OWNER_NAME="Hook Example"\n' > "$T/hookhome/config"
hk_payload() { python3 -c 'import json,sys; print(json.dumps({"session_id":"u1","cwd":"/tmp","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1"; }
out=$(hk_payload 'sudo reboot' | env -u SALA_OWNER_NAME SALA_CONFIG="$T/hookhome/config" HOME="$T/hookhome" "$ROOT/bin/salamander" hook pre-tool 2>&1)
case "$out" in *"Hook Example runs"*"sala reboot --go"*) ok "hook pre-tool: the name comes from the scratch config alone (none in the environment)";; *) bad "hook from config: $out";; esac
: > "$T/hookhome/config"
out=$(hk_payload 'sudo reboot' | env -u SALA_OWNER_NAME SALA_CONFIG="$T/hookhome/config" HOME="$T/hookhome" "$ROOT/bin/salamander" hook pre-tool 2>&1)
case "$out" in *"the owner runs"*"sala reboot --go"*) ok "hook pre-tool with no name anywhere says 'the owner'";; *) bad "hook with no name: $out";; esac
printf 'SALA_OWNER_NAME=%q\n' "$HOSTILE" > "$T/hookhome/config"
out=$(hk_payload 'sudo reboot' | env -u SALA_OWNER_NAME SALA_CONFIG="$T/hookhome/config" HOME="$T/hookhome" "$ROOT/bin/salamander" hook pre-tool 2>&1)
case "$out" in *'`touch'*|*'$('*) bad "hook: shell characters of the name reached the deny: $out";; *"Eve touch"*) ok "hook pre-tool cleans the name the same way";; *) bad "hook hostile: $out";; esac
[ ! -e "$T/pwn" ] && [ ! -e "$T/pwn2" ] && [ ! -e "$T/pwn3" ] && ok "and nothing in the name ran" || bad "a command in the name ran in the hook"

echo "== no config: the instance's page dirs, brain mirror, spec, units, backfill map, briefing and release-watch values are settings"
[ "$(sh_in "$EMPTY" 'echo "$SALA_PAGE_DIRS"')" = projects ] && ok "SALA_PAGE_DIRS defaults to projects" || bad "page dirs: $(sh_in "$EMPTY" 'echo "$SALA_PAGE_DIRS"')"
grep -qF ': "${SALA_BRAIN_DIR:=}"' "$ROOT/lib/side.sh" && ok "SALA_BRAIN_DIR (side done's brain mirror) is empty by default" || bad "SALA_BRAIN_DIR default"
[ -z "$(sh_in "$EMPTY" 'printf %s "$SALA_SETTINGS_SPEC_DIR"')" ] && ok "SALA_SETTINGS_SPEC_DIR is empty by default" || bad "spec dir: $(sh_in "$EMPTY" 'printf %s "$SALA_SETTINGS_SPEC_DIR"')"
out=$(sh_in "$EMPTY" 'sa_status 2>&1 | sed -n 2p'); case "$out" in "spec: (no spec: SALA_SETTINGS_SPEC_DIR is not set)"*) ok "settings-apply's status: no spec";; *) bad "spec status: $out";; esac
[ -z "$(sh_in "$EMPTY" 'printf %s "$SALA_SETTINGS_STEPS"')" ] && ok "SALA_SETTINGS_STEPS is empty by default (no instance step)" || bad "steps: $(sh_in "$EMPTY" 'printf %s "$SALA_SETTINGS_STEPS"')"
[ -z "$(sh_in "$EMPTY" 'printf %s "$SALA_SETTINGS_INPUTS"')" ] && ok "SALA_SETTINGS_INPUTS is empty by default (no instance file)" || bad "inputs: $(sh_in "$EMPTY" 'printf %s "$SALA_SETTINGS_INPUTS"')"
mkdir -p "$HOME/.config/salamander"; printf 'demo-skills\tdemo skills\n' > "$HOME/.config/salamander/step-words.tsv"
[ "$(sh_in "$EMPTY" 'step_word demo-skills; step_word repo')" = "demo skills
repo" ] && ok "a box's own step words (~/.config/salamander/step-words.tsv) are read before the tracked table" || bad "step words: $(sh_in "$EMPTY" 'step_word demo-skills')"
rm -f "$HOME/.config/salamander/step-words.tsv"
bad_units=$(grep -L '^X-Project=sala/salamander$' "$ROOT"/systemd/sala-watch.service "$ROOT"/systemd/sala-heartbeat.service "$ROOT"/contrib/briefing/systemd/*.service)
[ -z "$bad_units" ] && ok "sala's own units carry the neutral X-Project=sala/salamander" || bad "X-Project in: $bad_units"
out=$(env -u SALA_BACKFILL_MAP SALA_CONFIG="$EMPTY" bash "$ROOT/contrib/backfill-job-projects.sh" --dry-run 2>&1); rc=$?
[ $rc = 0 ] && case "$out" in *"no map"*) true;; *) false;; esac && ok "the job-project backfill has no built-in map (nothing to do)" || bad "backfill (rc=$rc): $out"
out=$(env -u BRIEFING_GMAIL_CONNECTOR -u BRIEFING_LOGDIR -u BRIEFING_WEBHOOK_FILE -u XDG_STATE_HOME SALA_CONFIG="$EMPTY" bash -c '. "$1/contrib/briefing/lib.sh" 2>/dev/null; echo "[$BRIEFING_GMAIL_CONNECTOR|$GMAIL_TOOLS|$PORTAL_GMAIL_READS|$OLD_LOGDIR]"; echo "${LOGDIR#$HOME/}"; echo "${WEBHOOK_FILE#$HOME/}"; briefing_need_connector summary && echo needs-none' _ "$ROOT")
[ "$out" = "[|||]
.local/state/sala-briefing
.config/sala-briefing/slack-webhook" ] && ok "the briefing: no connector, no Gmail tools, no old log directory, neutral paths, and a digest does not run" || bad "briefing defaults: $out"
out=$(env -u RELEASE_WATCH_CLI_OWNER SALA_CONFIG="$EMPTY" RELEASE_WATCH_STATE="$T/rw" RELEASE_WATCH_SALA=/nonexistent sh "$ROOT/contrib/briefing/release-watch.sh" cli-owner 2>/dev/null)
[ -z "$out" ] && ok "release-watch: no CLI owner without RELEASE_WATCH_CLI_OWNER" || bad "cli owner: $out"
out=$(env -u SALA_PAGE_DIRS -u SALA_BRAIN_DIR -u SALA_WEB_BRAIN_DIR -u SALA_WEB_PAGE_DIRS -u SALA_JOB_REPOS -u XDG_CONFIG_HOME SALA_CONFIG="$EMPTY" python3 -I -S -c 'import sys; sys.path.insert(0, sys.argv[1]); import sala_web.config as c, sala_web.schedules as s; print(c._brain_dir(), c._page_dirs(), s.KNOWN_REPOS, s.table_checkouts())' "$ROOT/web/src" 2>&1)
[ "$out" = "None ['projects'] ('salamander', 'stackshot') []" ] && ok "the web UI: no brain mirror, page dir projects, known repos salamander and stackshot only" || bad "web defaults: $out"
for v in SALA_BRAIN_DIR SALA_BACKFILL_MAP SALA_MACHINE_FOLLOW_MACHINES BRIEFING_GMAIL_CONNECTOR BRIEFING_LOGDIR BRIEFING_OLD_LOGDIR BRIEFING_WEBHOOK_FILE BRIEFING_LEAN_CLIENT_NAME BRIEFING_BRAIN_REPO BRIEFING_ISSUE_REPOS BRIEFING_GITHUB_BASE BRIEFING_TZ BRIEFING_WATCHLIST BRIEFING_LOW_PRIORITY_SENDERS BRIEFING_FORWARD_LABEL SALA_OWN_UNIT_PREFIXES \
         RELEASE_WATCH_CLI_OWNER RELEASE_WATCH_UBUNTU_SESSION RELEASE_WATCH_UBUNTU_PAGE; do
    grep -q "^#$v=" "$ROOT/config.example" && ok "$v is documented in config.example" || bad "$v is not in config.example"
done

[ "$fail" = 0 ] && echo "neutral-defaults: pass" || echo "neutral-defaults: FAIL"
exit "$fail"
