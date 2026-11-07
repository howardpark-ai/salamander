#!/usr/bin/env bash
# deploy.sh — bring the production checkout to origin/main. sala runs straight from this checkout
# (~/.local/bin/sala is a symlink into it), so whatever lands here is live at the next `sala` call. main is production:
# this checkout is deployed to, never worked in (CONTRIBUTING.md).
#
#   ./deploy.sh              the drift check, fetch, `bash -n` the incoming tree, fast-forward main, `bash -n` again on
#                            disk, re-run install.sh when the change needs it, one `changed:` line
#   ./deploy.sh --check      the drift check only: report, change nothing (no fetch; GitHub's main is read with ls-remote)
#   ./deploy.sh --dry-run    the drift check, fetch, and what a deploy would do (commits, files, install.sh, notes); the
#                            checkout is not touched (the fetch moves only the remote-tracking ref origin/main)
#   ./deploy.sh --web        the web step alone (below), in this checkout: after a deploy whose web step failed
#
# The web app lives under web/ (sala-web, once merged in; Wed Oct 14th 2026). A deploy that brings a file under web/ runs
# its own deploy after the fast-forward, the way its README does it: `uv sync --frozen` in web/, then
# `systemctl --user restart sala-web.service` (systemd holds the socket, so the restart drops no request). Nothing of
# that runs for a change elsewhere, and a web-only change runs nothing of sala's install (install.sh is re-run only for
# the files below). Without a web/pyproject.toml the step is a line and nothing else, so this is inert until web/ exists.
#
# The drift check refuses a checkout with uncommitted changes to tracked files (untracked files are only listed, and
# .claude/ not even that), one not on main, or one with commits that are not on origin/main.
# A deploy also waits for no one: it refuses while a recycle or revive holds the recycle lock, because a driver that
# sources lib/ halfway through its run would mix two versions (SALA_DEPLOY_LOCK_WAIT=<s> waits that long first; release.sh
# sets it).
# install.sh is re-run only when install.sh or config.example changed: it is idempotent and restarts nothing (two
# symlinks into this checkout, the config seeded only when missing, warnings; web units of the old name migrated, lib/webunits.sh).
# bin/salamander is linked, not copied, so a change to it needs no install. The systemd units are copied by hand, so a change under systemd/ is reported, not installed.
# Never restarts the tmux server, a session or a unit of sala's: the long-running pieces (sala-follow.service, a recycle's
# retry worker) keep the code they started with until their own next start, and the `note:` lines say so. The one unit
# it restarts is the web app's, sala-web.service, and only for a file under web/ (above).
# SALA_DEPLOY_CHECKOUT=<dir> points it at another checkout (default: the directory this script is in), so a branch's
# deploy.sh can check production before it is merged.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CO="$(cd "${SALA_DEPLOY_CHECKOUT:-$HERE}" && pwd)"
MODE=deploy
case "${1:-}" in
    '') ;;
    --check) MODE=check ;;
    --dry-run) MODE=dry ;;
    --web) MODE=web ;;
    -h|--help) sed -n '2,31p' "$0"; exit 0 ;;
    *) echo "usage: deploy.sh [--check | --dry-run | --web]" >&2; exit 2 ;;
esac
g() { git -C "$CO" "$@"; }
short() { g rev-parse --short "$1"; }
refuse() { echo "deploy refused: $*" >&2; exit 1; }

# The web step: the web app's venv synced to its lockfile, then its unit restarted (sala-web's own deploy, its README).
# Run after the fast-forward when a file under web/ (or lib/webunits.sh, this step's own code) changed, and by `--web` alone; never for a change elsewhere. An install
# whose web units still have their old name is migrated instead of restarted (lib/webunits.sh: the new units installed and
# started as the old ones ran, the old ones stopped, disabled and left as aliases, their drop-ins copied to the new units, the state
# directory moved (or merged into the new one, with the web service stopped: also on an install migrated earlier), the old socket paths and the old command kept working for one release).
. "$HERE/lib/webunits.sh"
deploy_web() {
    [ -f "$CO/web/pyproject.toml" ] || { echo "web: no web/pyproject.toml in $CO; nothing to sync or restart"; return 0; }
    command -v uv >/dev/null 2>&1 || { echo "web: uv is not on PATH; the venv was not synced and sala-web not restarted" >&2; return 1; }
    (cd "$CO/web" && uv sync --frozen 2>&1 | sed 's/^/  web: /'; exit "${PIPESTATUS[0]}") || { echo "web: uv sync --frozen failed in $CO/web; sala-web not restarted" >&2; return 1; }
    if web_legacy_name >/dev/null; then
        web_migrate "$CO" || { echo "web: the migration of the units from their old name failed" >&2; return 1; }
        echo "web: venv synced (uv sync --frozen in web/), units migrated to sala-web"
        return 0
    fi
    web_legacy_cmd_link "$CO" || return 1   # the old command's link, while the old name's units still exist as aliases
    web_state_merge || { echo "web: the old state directory could not be merged into the new one; sala-web not restarted" >&2; return 1; }
    systemctl --user restart sala-web.service || { echo "web: the restart of sala-web.service failed" >&2; return 1; }
    echo "web: venv synced (uv sync --frozen in web/), sala-web.service restarted"
}
if [ "$MODE" = web ]; then deploy_web || exit 1; exit 0; fi

# The shell files of a revision: tracked *.sh, bin/salamander, and anything whose first line is a sh/bash shebang.
shell_files_at() {
    local rev="$1" f
    g ls-tree -r --name-only "$rev" | while IFS= read -r f; do
        case "$f" in
            *.sh|bin/salamander) echo "$f" ;;
            *.py|*.md|*.c|*.plist|*.service|*.timer|*.yml|LICENSE|.gitignore) ;;
            *) first="$(g show "$rev:$f" 2>/dev/null | sed -n 1p)"; [[ "$first" =~ ^#!.*[/\ ](ba)?sh(\ |$) ]] && echo "$f" ;;
        esac
    done
}
syntax_at() {  # <rev> → 0 when every shell file of that revision parses; prints the ones that do not
    local rev="$1" f bad=0
    while IFS= read -r f; do
        if ! out="$(g show "$rev:$f" | bash -n 2>&1)"; then echo "  bash -n failed: $f: $(echo "$out" | sed -n 1p)" >&2; bad=1; fi
    done < <(shell_files_at "$rev")
    return $bad
}

# --- the drift check ---------------------------------------------------------------------------------------------------
drift=()
branch="$(g symbolic-ref --quiet --short HEAD 2>/dev/null || echo "detached HEAD at $(short HEAD)")"
[ "$branch" = main ] || drift+=("not on main ($branch)")
dirty="$(g status --porcelain --untracked-files=no)"
[ -z "$dirty" ] || drift+=("uncommitted changes to tracked files: $(echo "$dirty" | awk '{print $NF}' | sed -n 1,8p | paste -sd' ')")
g rev-parse --verify --quiet origin/main >/dev/null || refuse "no origin/main in $CO"
ahead="$(g rev-list --count origin/main..HEAD)"
[ "$ahead" = 0 ] || drift+=("$ahead commit(s) not on origin/main: $(g log -n5 --format=%h origin/main..HEAD | paste -sd' ')")
untracked="$(g status --porcelain --untracked-files=normal | sed -n 's/^?? //p' | grep -v '^\.claude/$' || true)"
behind="$(g rev-list --count HEAD..origin/main)"

if [ "$MODE" = check ]; then
    if [ ${#drift[@]} = 0 ]; then
        echo "drift check of $CO: clean — on main at $(short HEAD), no changes to tracked files, nothing that is not on origin/main"
    else
        echo "drift check of $CO: DRIFT"; printf '  %s\n' "${drift[@]}"
    fi
    [ -z "$untracked" ] || echo "  note: untracked files besides .claude/ (not drift, but a fast-forward that adds one of these paths fails): $(echo "$untracked" | sed -n 1,8p | paste -sd' ')"
    # the time in SALA_TZ (the environment, else the config file's line); with none set, this machine's own local time, labelled by its zone
    ZONE="$( (grep -E '^(export )?SALA_TZ=' "${SALA_CONFIG:-$HOME/.config/salamander/config}" 2>/dev/null || true) | tail -1 | cut -d= -f2- | sed -e 's/[[:space:]]*#.*$//' -e "s/[\"']//g" )"
    ZONE="${SALA_TZ:-$ZONE}"
    if [ -n "$ZONE" ]; then fetched="$(TZ="$ZONE" date -r "$(g rev-parse --path-format=absolute --git-path FETCH_HEAD)" '+%F %H:%M %Z' 2>/dev/null || true)"
    else fetched="$(date -r "$(g rev-parse --path-format=absolute --git-path FETCH_HEAD)" '+%F %H:%M %Z' 2>/dev/null || true)"; fi
    echo "  origin/main as last fetched${fetched:+ ($fetched)}: $(short origin/main); HEAD is $behind commit(s) behind it"
    if remote="$(g ls-remote --quiet origin refs/heads/main 2>/dev/null | cut -f1)" && [ -n "$remote" ]; then
        if [ "$remote" = "$(g rev-parse origin/main)" ]; then echo "  main on GitHub: ${remote:0:7}, the same"
        else echo "  main on GitHub: ${remote:0:7}, moved since the last fetch (a deploy fetches it)"; fi
    else
        echo "  main on GitHub: not reachable from here (ls-remote failed)"
    fi
    [ ${#drift[@]} = 0 ]; exit
fi

if [ ${#drift[@]} -gt 0 ]; then
    refuse "the production checkout $CO has drifted — $(IFS=';'; echo "${drift[*]}" | sed 's/;/; /g'). Work happens on a branch in a worktree, never here (CONTRIBUTING.md)"
fi

LOCK="$( (grep -E '^SALA_LOG_DIR=' "${SALA_CONFIG:-$HOME/.config/salamander/config}" 2>/dev/null || true) | tail -1 | cut -d= -f2- | tr -d '"' )"
LOCK="${SALA_LOG_DIR:-${LOCK:-$HOME/.claude}}"; LOCK="${LOCK/#\~/$HOME}/salamander-recycle.lock"
if command -v flock >/dev/null 2>&1 && [ -e "$LOCK" ] && ! flock -w "${SALA_DEPLOY_LOCK_WAIT:-0}" "$LOCK" true 2>/dev/null; then   # release.sh waits; by hand it is a refusal
    [ "$MODE" = dry ] && echo "note: a recycle or revive holds the recycle lock right now; a deploy would be refused until it ends" \
        || refuse "a recycle or revive holds the recycle lock ($LOCK); deploy once it has ended (sala's log says when)"
fi

# --- fetch and plan ------------------------------------------------------------------------------------------------------
if ! g fetch --quiet origin main 2>/dev/null; then
    url="$(g remote get-url origin 2>/dev/null | sed -E 's#//[^/@]*@#//#' || true)"     # never a credential that sits in the URL
    refuse "cannot fetch main from origin (${url:-no origin remote})"
fi
OLD="$(g rev-parse HEAD)"; NEW="$(g rev-parse origin/main)"
if [ "$OLD" = "$NEW" ]; then echo "already at origin/main ($(short HEAD)); nothing to deploy"; echo "changed: nothing"; exit 0; fi
g merge-base --is-ancestor "$OLD" "$NEW" || refuse "origin/main ($(short "$NEW")) does not contain HEAD ($(short "$OLD")); this checkout has commits of its own, or main was rewritten"
files="$(g diff --name-only "$OLD" "$NEW")"
ncommits="$(g rev-list --count "$OLD..$NEW")"; nfiles="$(echo "$files" | grep -c . || true)"
echo "deploying $(short "$OLD")..$(short "$NEW") to $CO, $ncommits commit(s):"; g log --oneline "$OLD..$NEW" | sed 's/^/  /'
echo "files:"; echo "$files" | sed 's/^/  /'
install=0; web=0; notes=()
while IFS= read -r f; do
    case "$f" in
        web/*|lib/webunits.sh) web=1 ;;   # the web app (and lib/webunits.sh, the web step's own code): deploy_web after the fast-forward; nothing of sala's install for it
        install.sh|config.example) install=1 ;;
        systemd/*) notes+=("$f changed: the installed copy in ~/.config/systemd/user is not updated by a deploy; copy it and daemon-reload by hand, and restart the unit when it suits") ;;
        lib/follow.*|lib/common.sh|bin/salamander) notes+=("$f changed: sala-follow.service is resident and keeps the code it started with until its next restart (a deploy restarts nothing)") ;;
    esac
done <<< "$files"
[ $install = 1 ] && echo "install.sh: re-run (install.sh or config.example changed)" || echo "install.sh: not needed"
[ $web = 0 ] || echo "web/: a file under web/ changed: after the fast-forward, uv sync --frozen in web/ and a restart of sala-web.service"
[ $web = 0 ] || ! old_web="$(web_legacy_name)" || echo "web/: the web units are installed under their old name ($old_web.*): the web step migrates them to sala-web instead of the restart"
[ ${#notes[@]} = 0 ] || printf 'note: %s\n' "${notes[@]}" | awk '!seen[$0]++'
syntax_at "$NEW" || refuse "a shell file of origin/main ($(short "$NEW")) does not parse; nothing was changed here"
echo "bash -n: the incoming tree parses"
summary="changed: $(short "$OLD")..$(short "$NEW"), $ncommits commit(s), $nfiles file(s) ($(echo "$files" | sed -n 1,6p | paste -sd' ')$([ "$nfiles" -le 6 ] || echo " …")); install.sh $([ $install = 1 ] && echo re-run || echo 'not needed')$([ $web = 0 ] || echo '; web: sala-web synced and restarted')"
if [ "$MODE" = dry ]; then echo "dry run: nothing changed; a deploy would print:"; echo "  $summary"; exit 0; fi

# --- land it -------------------------------------------------------------------------------------------------------------
g merge --ff-only --quiet origin/main
syntax_at HEAD || { echo "deploy: bash -n fails on disk after the fast-forward (main is at $(short HEAD)); investigate before the next sala call" >&2; exit 1; }
if [ $install = 1 ]; then "$CO/install.sh" 2>&1 | sed 's/^/  install: /'; fi
if [ $web = 1 ]; then deploy_web || { echo "deploy: the web step failed after the fast-forward (main is at $(short HEAD), sala's side is deployed); fix the cause and run ./deploy.sh --web in $CO" >&2; exit 1; }; fi
echo "$summary"
