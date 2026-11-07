#!/usr/bin/env bash
# slack_links, the linker post_slack runs after slack_text (board): only what can stop a post from going out
# (the link-shape checks were dropped as formatting). A hung sala is cut off, and the real post_slack, run against a
# listener on 127.0.0.1 with the linker made to fail or print nothing, still sends the post.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd); LIB=$ROOT/contrib/briefing/lib.sh
fail=0; ok() { echo "  ok   $*"; }; bad() { echo "  FAIL $*"; fail=1; }
T=$(mktemp -d); trap 'kill "${SRV:-}" 2>/dev/null; rm -rf "$T"' EXIT
export BRIEFING_LOGDIR="$T/logs"   # unset, lib.sh would migrate the real old ~/.cache directory
printf 'NAME                     VERSION    BRIDGE\n' > "$T/sessions"
mkdir -p "$T/board-data/s" "$T/board-data/g"; echo '{}' > "$T/board-data/s/6.json"; echo '{}' > "$T/board-data/g/46.json"
export BRIEFING_SESSIONS_CMD="cat $T/sessions" BRIEFING_BOARD_DIR=$T/board-data BRIEFING_COMMIT_REPOS=
lnk() { bash -c '. "$1"; slack_links "$2"' _ "$LIB" "$1"; }
export SALA_STACKSHOT_WEB=https://board.example.com/   # the board's web address (sala's setting; a trailing / is dropped)
SS=https://board.example.com/items
export BRIEFING_GITHUB_BASE=https://github.com/example-org   # the GitHub account the repo links point into (an invented one)

# a session links to sala's own session link, bridged or not; an unknown name stays plain
SALA=https://sala.example.com/#s=
printf "SALA_SESSION_URL=%s\n" "${SALA}{name}" > "$T/config"; export SALA_CONFIG=$T/config   # the units do not set the link: they read it from the sala config
printf 'NAME                     VERSION    BRIDGE\nalpha-main               2.1.306    session_01ABC\nbeta-engineer            2.1.306    —\nx.*                      2.1.306    session_01XYZ\na+b(1)                   2.1.306    —\nold-shell                (shell)    claude exited — revive: salamander revive --only old-shell   (sidecar 1234abcd…)\n?                        2.1.306    —\n' > "$T/sessions"
unset SALA_SESSION_URL SALA_FLEET_HOSTS
got=$(lnk 'alpha-main is up'); [ "$got" = "<${SALA}alpha-main|alpha-main> is up" ] && ok "a session with a bridge links to sala, not claude.ai" || bad "bridged: $got"
got=$(lnk 'beta-engineer, done'); [ "$got" = "<${SALA}beta-engineer|beta-engineer>, done" ] && ok "a session without a bridge links to sala" || bad "unbridged: $got"
got=$(lnk 'old-shell stopped'); [ "$got" = "<${SALA}old-shell|old-shell> stopped" ] && ok "a listed session whose claude exited links to sala" || bad "shell row: $got"
got=$(lnk 'gamma-main and alpha-main-2'); [ "$got" = 'gamma-main and alpha-main-2' ] && ok "an unknown name (and a longer one that merely starts like a session) stays plain" || bad "unknown: $got"
got=$(lnk 'x.* then xyz and a+b(1) and aab'); [ "$got" = "<${SALA}x.*|x.*> then xyz and <${SALA}a%2Bb(1)|a+b(1)> and aab" ] \
    && ok "a name with regex characters links as itself (encoded in the url) and matches nothing else" || bad "regex name: $got"
got=$(lnk 'ask ? first'); [ "$got" = 'ask ? first' ] && ok "the registry's '?' placeholder name is never linked" || bad "placeholder: $got"
got=$(lnk 'in `alpha-main` and <https://x.y/alpha-main|alpha-main>'); [ "$got" = 'in `alpha-main` and <https://x.y/alpha-main|alpha-main>' ] && ok "code spans and existing links are still left alone" || bad "kept: $got"
got=$(lnk 'alpha-main s6 salamander#5'); [ "$got" = "<${SALA}alpha-main|alpha-main> <$SS/s6|s6> <https://github.com/example-org/salamander/issues/5|salamander#5>" ] && ok "board ids and repo#N still link" || bad "other kinds: $got"
got=$(lnk 'see g46 now'); [ "$got" = "see <$SS/46|board#46> now" ] && ok "a store id g46 in the board data links to items/46, shown as board#46" || bad "store id: $got"
# page slugs and repo#N: a slug links into BRIEFING_BRAIN_REPO (none set: plain), its dirs SALA_PAGE_DIRS plus people and companies;
# repo#N for the repos of BRIEFING_ISSUE_REPOS (default salamander and stackshot); the config's lines count when the environment has none
GH=https://github.com/example-org
got=$(lnk 'see projects/demo and ops/demo-plan, demo-repo#3'); [ "$got" = 'see projects/demo and ops/demo-plan, demo-repo#3' ] && ok "no BRIEFING_BRAIN_REPO: a page slug stays plain; a repo not in BRIEFING_ISSUE_REPOS too" || bad "slug default: $got"
got=$(BRIEFING_BRAIN_REPO=demo-pages SALA_PAGE_DIRS="projects ops" BRIEFING_ISSUE_REPOS="demo-repo salamander" lnk 'see projects/demo and ops/demo-plan.md, people/alex, demo-repo#3 stackshot#4')
[ "$got" = "see <$GH/demo-pages/blob/main/projects/demo.md|projects/demo> and <$GH/demo-pages/blob/main/ops/demo-plan.md|ops/demo-plan.md>, <$GH/demo-pages/blob/main/people/alex.md|people/alex>, <$GH/demo-repo/issues/3|demo-repo#3> stackshot#4" ] \
    && ok "BRIEFING_BRAIN_REPO, SALA_PAGE_DIRS and BRIEFING_ISSUE_REPOS: slugs in those dirs and the listed repos link" || bad "slug set: $got"
printf "SALA_SESSION_URL=%s\nBRIEFING_BRAIN_REPO=demo-pages\nBRIEFING_ISSUE_REPOS='demo-repo'\n" "${SALA}{name}" > "$T/config2"
got=$(SALA_CONFIG=$T/config2 lnk 'projects/demo demo-repo#3'); [ "$got" = "<$GH/demo-pages/blob/main/projects/demo.md|projects/demo> <$GH/demo-repo/issues/3|demo-repo#3>" ] && ok "the brain and issue repos from the sala config" || bad "slug config: $got"
# BRIEFING_GITHUB_BASE: the account every GitHub link points into (a trailing / is dropped, its last path segment is the owner `<owner>/<repo>#N` may carry);
# unset, empty or not a URL ending in an account: no GitHub link at all (slug, repo#N, owner/repo#N and commit stay plain)
got=$(BRIEFING_GITHUB_BASE=https://github.com/example-org/ lnk 'salamander#5 example-org/salamander#5 other-org/salamander#5'); [ "$got" = "<$GH/salamander/issues/5|salamander#5> <$GH/salamander/issues/5|example-org/salamander#5> other-org/salamander#5" ] \
    && ok "a trailing / on BRIEFING_GITHUB_BASE is dropped; the owner prefix of the base is accepted, another owner's is not" || bad "base with slash: $got"
got=$(BRIEFING_GITHUB_BASE=https://git.example.net:8443/scm/team lnk 'salamander#5 team/stackshot#6'); [ "$got" = '<https://git.example.net:8443/scm/team/salamander/issues/5|salamander#5> <https://git.example.net:8443/scm/team/stackshot/issues/6|team/stackshot#6>' ] \
    && ok "another host and a deeper path: the base is used as given, the owner is its last segment" || bad "other host: $got"
printf "SALA_SESSION_URL=%s\nBRIEFING_GITHUB_BASE=https://github.com/cfg-org\n" "${SALA}{name}" > "$T/config3"
got=$(unset BRIEFING_GITHUB_BASE; SALA_CONFIG=$T/config3 lnk 'salamander#5'); [ "$got" = '<https://github.com/cfg-org/salamander/issues/5|salamander#5>' ] && ok "BRIEFING_GITHUB_BASE from the sala config when the environment has none" || bad "base config: $got"
git init -q "$T/gitrepo"   # a commit id is linked only if it holds a digit and a letter a-f: commit until one does
for i in 1 2 3 4 5 6 7 8; do
    git -C "$T/gitrepo" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m "c$i"; sha=$(git -C "$T/gitrepo" rev-parse --short=12 HEAD)
    printf '%s' "$sha" | grep -q '[0-9]' && printf '%s' "$sha" | grep -q '[a-f]' && break
done
msg="fixed in $sha, see salamander#5 and projects/demo"
got=$(BRIEFING_COMMIT_REPOS="demo=$T/gitrepo" BRIEFING_BRAIN_REPO=demo-pages lnk "$msg"); [ "$got" = "fixed in <$GH/demo/commit/$sha|$sha>, see <$GH/salamander/issues/5|salamander#5> and <$GH/demo-pages/blob/main/projects/demo.md|projects/demo>" ] \
    && ok "commit, repo#N and page links all build on BRIEFING_GITHUB_BASE" || bad "all kinds: $got"
for v in unset empty bad; do
    case $v in unset) pre='env -u BRIEFING_GITHUB_BASE' ;; empty) pre='env BRIEFING_GITHUB_BASE=' ;; bad) pre='env BRIEFING_GITHUB_BASE=github.com/example-org' ;; esac
    got=$($pre BRIEFING_COMMIT_REPOS="demo=$T/gitrepo" BRIEFING_BRAIN_REPO=demo-pages SALA_CONFIG=$T/config bash -c '. "$1"; slack_links "$2"' _ "$LIB" "$msg, example-org/salamander#5, alpha-main s6")
    [ "$got" = "fixed in $sha, see salamander#5 and projects/demo, example-org/salamander#5, <${SALA}alpha-main|alpha-main> <$SS/s6|s6>" ] \
        && ok "BRIEFING_GITHUB_BASE $v: repo#N, owner/repo#N, page slug and commit stay plain; session and board links unaffected" || bad "base $v: $got"
done
# the template: SALA_SESSION_URL when set, empty meaning the claude.ai link of a bridged session only, else the SALA_SESSION_URL line of the sala config (none: no web link, claude.ai for a bridged session)
got=$(SALA_SESSION_URL='https://t.example/s/{name}' lnk 'beta-engineer'); [ "$got" = '<https://t.example/s/beta-engineer|beta-engineer>' ] && ok "SALA_SESSION_URL sets the template" || bad "custom tpl: $got"
got=$(SALA_SESSION_URL= lnk 'alpha-main beta-engineer'); [ "$got" = '<https://claude.ai/code/session_01ABC|alpha-main> beta-engineer' ] && ok "an empty SALA_SESSION_URL: claude.ai for a bridged session, plain for one without" || bad "empty tpl: $got"
got=$(SALA_CONFIG=$T/no-such-config lnk 'alpha-main beta-engineer'); [ "$got" = '<https://claude.ai/code/session_01ABC|alpha-main> beta-engineer' ] && ok "no config and no variable: no web link of ours (claude.ai for a bridged session, plain for one without)" || bad "no config: $got"
# the board's web address: SALA_STACKSHOT_WEB when set (empty too), else its line in the sala config; none: board ids stay plain
got=$(SALA_STACKSHOT_WEB= lnk 'see s6'); [ "$got" = 'see s6' ] && ok "an empty SALA_STACKSHOT_WEB: a board id stays plain" || bad "empty board web: $got"
got=$(env -u SALA_STACKSHOT_WEB SALA_CONFIG=$T/no-such-config bash -c '. "$1"; slack_links "$2"' _ "$LIB" 'see s6'); [ "$got" = 'see s6' ] && ok "no SALA_STACKSHOT_WEB and no config: a board id stays plain, no error" || bad "no board web: $got"
printf 'SALA_STACKSHOT_WEB=https://cfg.example.org\n' > "$T/config-web"
got=$(env -u SALA_STACKSHOT_WEB SALA_CONFIG=$T/config-web bash -c '. "$1"; slack_links "$2"' _ "$LIB" 'see s6'); [ "$got" = 'see <https://cfg.example.org/items/s6|s6>' ] && ok "SALA_STACKSHOT_WEB from the sala config links a board id" || bad "config board web: $got"
# the [gmail:] marker: BRIEFING_GMAIL_ACCOUNT picks the account (env or the config line); unset, the first signed-in one
got=$(lnk 'see [gmail:18c0ab]'); [ "$got" = 'see <https://mail.google.com/mail/u/0/#all/18c0ab|open>' ] && ok "no BRIEFING_GMAIL_ACCOUNT: the mail link opens the first signed-in account" || bad "gmail default: $got"
got=$(BRIEFING_GMAIL_ACCOUNT=alex@example.com lnk 'see [gmail:18c0ab]'); [ "$got" = 'see <https://mail.google.com/mail/u/?authuser=alex@example.com#all/18c0ab|open>' ] && ok "BRIEFING_GMAIL_ACCOUNT: the mail link opens that account" || bad "gmail account: $got"
# the config is READ, never sourced: a line with a side effect does not run, a quoted value with a trailing comment is the value, the last assignment wins
printf 'touch "%s/sourced"\nSALA_SESSION_URL=https://old.example/s/{name}\nexport SALA_SESSION_URL="https://c.example/s/{name}"   # the link\nSALA_X=$(touch "%s/sourced")\n' "$T" "$T" > "$T/config2"
got=$(SALA_CONFIG=$T/config2 lnk 'alpha-main'); [ "$got" = '<https://c.example/s/alpha-main|alpha-main>' ] && [ ! -e "$T/sourced" ] && ok "the config's session link is read without sourcing the config (nothing else in it runs)" || bad "config read: $got, sourced=$([ -e "$T/sourced" ] && echo yes || echo no)"
# the encoding is lib/common.sh's session_url: same url for awkward names, for the same template
for n in "a/b?c#d~*'()" 'é日本' 'x.*' 'a+b(1)' 'plain-name_1.x'; do
    want=$(HOME=$T SALA_LOG_DIR=$T SALA_STATE_DIR=$T SALA_SESSION_URL="${SALA}{name}" bash -c '. "$1/lib/common.sh" >/dev/null 2>&1; session_url "$2" ""' _ "$ROOT" "$n")
    printf 'NAME VERSION BRIDGE\n%s 1 —\n' "$n" > "$T/sessions2"
    mine=$(BRIEFING_SESSIONS_CMD="cat $T/sessions2" lnk "$n")
    [ -n "$want" ] && [ "$mine" = "<$want|$n>" ] && ok "same url as session_url for '$n'" || bad "session_url differs for '$n': $mine / $want"
done

start=$(date +%s); got=$(BRIEFING_SESSIONS_CMD="sleep 30" lnk 's6'); took=$(( $(date +%s) - start ))
[ "$got" = "<$SS/s6|s6>" ] && [ "$took" -le 8 ] && ok "a hung sala is cut off at 5 s (${took}s)" || bad "hung sala: ${took}s, $got"

# the names come from sala's registry (`sala sessions --json`: rows not retired), not `sala spawn --list`, which took 5-6 s
# during a recycle and lost the links under the old 5 s cap. BRIEFING_SESSIONS_CMD is the legacy
# whole-lookup override the checks above use; these run without it. The registry is a fake file, the fallback a fake command.
reg() { BRIEFING_SESSIONS_CMD= BRIEFING_REGISTRY_CMD="cat $T/reg.json" BRIEFING_SPAWN_LIST_CMD="cat $T/sessions" lnk "$1"; }
printf '{"schema":1,"sessions":[{"name":"reg-main","state":"live"},{"name":"reg-gone","state":"retired"},{"name":"reg-shell","state":"live"},{"name":"two words","state":"live"},{"state":"live"}]}\n' > "$T/reg.json"
got=$(reg 'reg-main reg-gone reg-shell alpha-main'); [ "$got" = "<${SALA}reg-main|reg-main> reg-gone <${SALA}reg-shell|reg-shell> alpha-main" ] \
    && ok "names come from the registry: live rows link, a retired row and a name only the fallback lists stay plain" || bad "registry: $got"
for kind in empty invalid; do   # a registry with no live row, or output that is not the registry's JSON: fall back to spawn --list
    case $kind in empty) echo '{"schema":1,"sessions":[]}' > "$T/reg.json" ;; invalid) echo 'the session registry is empty' > "$T/reg.json" ;; esac
    got=$(reg 'alpha-main reg-main'); [ "$got" = "<${SALA}alpha-main|alpha-main> reg-main" ] && ok "the $kind registry falls back to spawn --list" || bad "$kind registry: $got"
done
rm -f "$T/reg.json"
got=$(reg 'alpha-main'); [ "$got" = "<${SALA}alpha-main|alpha-main>" ] && ok "a missing registry file (cat fails) falls back to spawn --list" || bad "missing registry: $got"
got=$(BRIEFING_SESSIONS_CMD= BRIEFING_REGISTRY_CMD=false BRIEFING_SPAWN_LIST_CMD="sleep 30" BRIEFING_SPAWN_LIST_CAP=2 lnk 's6'); [ "$got" = "<$SS/s6|s6>" ] && ok "a hung fallback is cut off at its cap and the post still goes" || bad "hung fallback: $got"
# the fallback's real default cap (20 s) outlasts the old 5 s one: a spawn --list that takes 6 s still links (costs 6 s here)
printf '#!/bin/sh\nsleep 6\nprintf "NAME VERSION BRIDGE\\nslow-main 1 -\\n"\n' > "$T/slow.sh"; chmod +x "$T/slow.sh"
start=$(date +%s); got=$(BRIEFING_SESSIONS_CMD= BRIEFING_REGISTRY_CMD=false BRIEFING_SPAWN_LIST_CMD="$T/slow.sh" lnk 'slow-main'); took=$(( $(date +%s) - start ))
[ "$got" = "<${SALA}slow-main|slow-main>" ] && [ "$took" -ge 6 ] && [ "$took" -le 12 ] && ok "a 6 s spawn --list fallback still links under the 20 s default cap (${took}s)" || bad "slow fallback: ${took}s, $got"

# the fallback: the real post_slack, the linker made to fail or print nothing, against a listener on 127.0.0.1
python3 - "$T/port" "$T/body" 3 <<'PY' &
import http.server, sys
port_file, body, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
seen = [0]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        seen[0] += 1
        open(f"{body}.{seen[0]}", "wb").write(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(port_file, "w").write(str(s.server_address[1]))
for _ in range(n): s.handle_request()
PY
SRV=$!
for _ in $(seq 50); do [ -s "$T/port" ] && break; sleep 0.1; done
if [ -s "$T/port" ]; then
    printf 'http://127.0.0.1:%s/hook\n' "$(cat "$T/port")" > "$T/webhook"
    post() { bash -c '. "$1" 2>/dev/null; WEBHOOK_FILE=$2/webhook; eval "$3"; post_slack "$4"' _ "$LIB" "$T" "$1" "$2"; }
    sent() { python3 -c 'import json,sys; sys.stdout.write(json.load(open(sys.argv[1], encoding="utf-8"))["text"])' "$T/body.$1" 2>/dev/null; }
    r1=$(post ':' '**Done** on s6 in ~/x')
    r2=$(post 'slack_links() { echo partial; return 1; }' '**Done** on s6 in ~/x')
    r3=$(post 'slack_links() { :; }' '**Done** on s6 in ~/x')
    wait "$SRV" 2>/dev/null; SRV=
    [ "$r1$r2$r3" = okokok ] && ok "post_slack: listener answered all three" || bad "post_slack responses: $r1/$r2/$r3"
    [ "$(sent 1)" = "*Done* on <$SS/s6|s6> in \`~/x\`" ] && ok "post_slack: formatted, then linked" || bad "post 1: $(sent 1)"
    [ "$(sent 2)" = '*Done* on s6 in `~/x`' ] && ok "post_slack: a failing linker still sends the formatted text" || bad "post 2: $(sent 2)"
    [ "$(sent 3)" = '*Done* on s6 in `~/x`' ] && ok "post_slack: an empty linker result still sends the formatted text" || bad "post 3: $(sent 3)"
else
    bad "the 127.0.0.1 listener did not start"
fi
exit $fail
