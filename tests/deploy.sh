#!/usr/bin/env bash
# deploy.sh's web step (Wed Oct 14th 2026): a file under web/ (the web app; sala-web, once it lives there) is deployed by a
# `uv sync --frozen` in web/ and a restart of sala-web.service, nothing of that runs for a change elsewhere, and sala's own
# path is as it was. It stays tested because a deploy lands under every live session's feet, and a wrong detection would
# restart a real unit for nothing or leave the web app on old code. Against a throwaway origin and a clone standing in
# for the production checkout (SALA_DEPLOY_CHECKOUT), with a fake `uv` and a fake `systemctl` on PATH that only log what
# they were asked, so no real unit, venv or checkout is touched. Checks: web/ without a pyproject (a line, nothing run),
# a web-only change (its dry run says it and runs nothing; for real: synced, restarted, nothing of sala's install), a
# lib-only change (neither; sala's note as before), install.sh changed (re-run as before), both, the web step failing
# after the fast-forward (exit 1, the sala side landed, the last line names --web), --web by hand, nothing to deploy; and the drift check's
# fetch time, written in SALA_TZ's zone (the environment or sala's config file) with the zone's own label, else in this machine's local time;
# and an install whose web units still have their old name (lib/webunits.sh): its dry run says so, the deploy migrates them
# (old units stopped and aliased, their drop-ins copied to the new units, new ones started, the state moved, the old socket path in a
# drop-in, the old command linked to sala-web in the venv), the next web step restarts and makes the link again when it is gone.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
export HOME=$(mktemp -d); mkdir -p "$HOME/bin"; export PATH="$HOME/bin:$PATH"
unset SALA_CONFIG SALA_LOG_DIR SALA_DEPLOY_LOCK_WAIT SALA_DEPLOY_CHECKOUT XDG_CONFIG_HOME XDG_STATE_HOME
trap 'rm -rf "$HOME"' EXIT
export FAKE_LOG="$HOME/calls"
cat > "$HOME/bin/uv" <<'FAKE'
#!/bin/bash
echo "uv $* (in $PWD)" >> "$FAKE_LOG"
[ -z "${FAKE_UV_FAIL:-}" ] || { echo "error: the lockfile needs to be updated" >&2; exit 1; }
echo "Audited 3 packages"
FAKE
cat > "$HOME/bin/systemctl" <<'FAKE'
#!/bin/bash
echo "systemctl $*" >> "$FAKE_LOG"
FAKE
chmod +x "$HOME/bin/uv" "$HOME/bin/systemctl"

ORIGIN="$HOME/origin.git"; WORK="$HOME/work"; PROD="$HOME/prod"
git init -q --bare -b main "$ORIGIN"
git init -q -b main "$WORK"; git -C "$WORK" config user.email t@t; git -C "$WORK" config user.name t; git -C "$WORK" remote add origin "$ORIGIN"
push() { git -C "$WORK" add -A; git -C "$WORK" commit -q -m "$1"; git -C "$WORK" push -q origin main; }
commit() {  # <message> <file>… → each file written as one comment line (a shell file parses), committed and pushed
    local m="$1"; shift; local f
    for f in "$@"; do mkdir -p "$WORK/$(dirname "$f")"; echo "# $m $f" > "$WORK/$f"; done
    push "$m"
}
commit base lib/common.sh README.md
printf '#!/bin/bash\necho installed\n' > "$WORK/install.sh"; chmod +x "$WORK/install.sh"; push install
git clone -q "$ORIGIN" "$PROD"
deploy() { out=$(SALA_DEPLOY_CHECKOUT="$PROD" bash "$ROOT/deploy.sh" "$@" 2>&1); rc=$?; }
calls() { cat "$FAKE_LOG" 2>/dev/null; }
landed() { [ "$(git -C "$PROD" rev-parse HEAD)" = "$(git -C "$WORK" rev-parse HEAD)" ]; }
WEB_CALLS="uv sync --frozen (in $PROD/web)"$'\n'"systemctl --user restart sala-web.service"

echo "== the drift check names the time origin/main was last fetched in SALA_TZ's zone, else this machine's local time"
git -C "$PROD" fetch -q origin
out=$(SALA_CONFIG=/dev/null SALA_TZ=Asia/Kolkata SALA_DEPLOY_CHECKOUT="$PROD" bash "$ROOT/deploy.sh" --check 2>&1)
[[ $out == *"origin/main as last fetched ("*" IST)"* ]] && ok "SALA_TZ=Asia/Kolkata: the fetch time is labelled IST" || bad "zone set: $out"
out=$(env -u SALA_TZ TZ=America/New_York SALA_CONFIG=/dev/null SALA_DEPLOY_CHECKOUT="$PROD" bash "$ROOT/deploy.sh" --check 2>&1)
[[ $out == *"origin/main as last fetched ("*" E"[SD]"T)"* ]] && ok "SALA_TZ unset: the machine's local zone and its own label (no fixed label)" || bad "zone unset: $out"
printf 'SALA_TZ=Europe/Berlin   # a note\n' > "$HOME/tz-config"
out=$(env -u SALA_TZ SALA_CONFIG="$HOME/tz-config" SALA_DEPLOY_CHECKOUT="$PROD" bash "$ROOT/deploy.sh" --check 2>&1); rm -f "$HOME/tz-config"
[[ $out == *"origin/main as last fetched ("*" CE"[ST]")"* ]] && ok "SALA_TZ only in sala's config file: read from there" || bad "zone in config: $out"

echo "== web/ without a pyproject"
commit webreadme web/README.md; : > "$FAKE_LOG"; deploy
[ "$rc" = 0 ] && [[ $out == *"web: no web/pyproject.toml"* ]] && [ ! -s "$FAKE_LOG" ] && landed \
    && ok "a web/ file with no pyproject: landed, said, nothing synced or restarted" || bad "no pyproject: rc=$rc calls=$(calls) $out"

echo "== a web-only change"
commit webadd web/pyproject.toml web/src/app.py; : > "$FAKE_LOG"; deploy --dry-run
[ "$rc" = 0 ] && [[ $out == *"web/: a file under web/ changed"* ]] && [[ $out == *"web: sala-web synced and restarted"* ]] && [ ! -s "$FAKE_LOG" ] && ! landed \
    && ok "dry run: the web step said, nothing run, nothing landed" || bad "dry run: rc=$rc calls=$(calls) $out"
deploy
[ "$rc" = 0 ] && [ "$(calls)" = "$WEB_CALLS" ] && [[ $out == *"web: venv synced"* ]] && [[ $out == *"changed: "*"install.sh not needed; web: sala-web synced and restarted"* ]] \
    && [[ $out != *"install: "* ]] && landed \
    && ok "for real: landed, uv sync --frozen in web/, then the restart, nothing of sala's install" || bad "web-only: rc=$rc calls=$(calls) $out"

echo "== a change elsewhere"
commit lib lib/common.sh; : > "$FAKE_LOG"; deploy
[ "$rc" = 0 ] && [ ! -s "$FAKE_LOG" ] && [[ $out != *web* ]] && [[ $out == *"note: lib/common.sh changed"* ]] && [[ $out == *"install.sh not needed"* ]] && landed \
    && ok "lib only: nothing synced or restarted, no web line, sala's note as before" || bad "lib: rc=$rc calls=$(calls) $out"
echo 'echo again' >> "$WORK/install.sh"; push install2; : > "$FAKE_LOG"; deploy
[ "$rc" = 0 ] && [[ $out == *"install.sh: re-run"* ]] && [[ $out == *"install: installed"* ]] && [ ! -s "$FAKE_LOG" ] && landed \
    && ok "install.sh changed: re-run as before, nothing of the web's" || bad "install: rc=$rc calls=$(calls) $out"

echo "== both"
commit both lib/common.sh web/src/app.py; : > "$FAKE_LOG"; deploy
[ "$rc" = 0 ] && [ "$(calls)" = "$WEB_CALLS" ] && [[ $out == *"note: lib/common.sh changed"* ]] && [[ $out == *"web: sala-web synced and restarted"* ]] && landed \
    && ok "both: sala's path as before and the web step after it" || bad "both: rc=$rc calls=$(calls) $out"

echo "== the web step failing"
commit webfail web/src/app.py; : > "$FAKE_LOG"; FAKE_UV_FAIL=1 deploy
[ "$rc" = 1 ] && landed && [ "$(calls)" = "uv sync --frozen (in $PROD/web)" ] && [[ "$(echo "$out" | tail -1)" == *"run ./deploy.sh --web in $PROD"* ]] && ! echo "$out" | grep -q '^changed: ' \
    && ok "uv failing: exit 1, the fast-forward done, no restart, the last line names --web" || bad "fail: rc=$rc calls=$(calls) $out"
: > "$FAKE_LOG"; deploy --web
[ "$rc" = 0 ] && [ "$(calls)" = "$WEB_CALLS" ] && [[ $out == *"web: venv synced"* ]] && ok "--web by hand: the sync and the restart, nothing else" || bad "--web: rc=$rc calls=$(calls) $out"
: > "$FAKE_LOG"; deploy
[ "$rc" = 0 ] && [[ $out == *"already at origin/main"* ]] && [ ! -s "$FAKE_LOG" ] && ok "nothing to deploy: nothing run" || bad "nothing: rc=$rc calls=$(calls) $out"

echo "== a web change on an install whose web units still have their old name: migrated instead of restarted"
# the real units in the incoming tree (web_units_install copies them); the old ones under a neutral stand-in name, as an
# install.sh --web of the old name wrote them for this checkout; the venv already has the new command (the fake uv makes none)
mkdir -p "$WORK/web/contrib"; cp "$ROOT"/web/contrib/sala-web* "$WORK/web/contrib/"; push "web units"
U="$HOME/.config/systemd/user"; X=legacy-ui; mkdir -p "$U" "$HOME/.local/state/$X" "$PROD/web/.venv/bin"
printf '#!/bin/sh\n' > "$PROD/web/.venv/bin/sala-web"; chmod +x "$PROD/web/.venv/bin/sala-web"
printf '[Unit]\nRequires=%s.socket\n[Service]\nExecStart=%%h/prod/web/.venv/bin/%s\n' "$X" "$X" > "$U/$X.service"
printf '[Socket]\nListenStream=%%t/%s/%s.sock\n' "$X" "$X" > "$U/$X.socket"
echo state > "$HOME/.local/state/$X/f"
mkdir -p "$U/$X.service.d" "$U/$X.socket.d"; printf '[Unit]\nAssertPathExists=/srv/lease/ok\n' | tee "$U/$X.service.d/10-lease-guard.conf" > "$U/$X.socket.d/10-lease-guard.conf"
: > "$FAKE_LOG"; deploy --dry-run
[ "$rc" = 0 ] && [[ $out == *"installed under their old name ($X.*): the web step migrates them"* ]] && [ ! -s "$FAKE_LOG" ] && [ ! -L "$U/$X.service" ] \
    && ok "dry run: the migration said, nothing run" || bad "dry run: rc=$rc calls=$(calls) $out"
: > "$FAKE_LOG"; deploy
[ "$rc" = 0 ] && landed && [[ $out == *"units migrated to sala-web"* ]] && ! grep -q 'restart' "$FAKE_LOG" \
    && grep -qx "systemctl --user stop $X.service" "$FAKE_LOG" && grep -qx "systemctl --user stop $X.socket" "$FAKE_LOG" \
    && grep -qx "systemctl --user start sala-web.service sala-web.socket" "$FAKE_LOG" \
    && ok "for real: landed, the old units stopped, the new ones started, no restart" || bad "migrate: rc=$rc calls=$(calls) $out"
[ "$(readlink "$U/$X.service")" = sala-web.service ] && [ "$(readlink "$U/$X.socket")" = sala-web.socket ] && [ -f "$U/sala-web.service" ] \
    && [ "$(cat "$HOME/.local/state/sala-web/f")" = state ] && grep -qx "Environment=SALA_WEB_COMPAT_SOCKET=%t/$X/$X.sock" "$U/sala-web.service.d/old-socket-path.conf" \
    && ! grep -q TTYD "$U/sala-web.service.d/old-socket-path.conf" \
    && ok "aliases in place, the state moved, the old app socket path in the drop-in (no ttyd unit, no ttyd path)" || bad "after: $(ls -l "$U") $(ls "$HOME/.local/state")"
for k in service socket; do cmp -s "$U/$X.$k.d/10-lease-guard.conf" "$U/sala-web.$k.d/10-lease-guard.conf" || cdrop=bad; done
[ -z "${cdrop:-}" ] && [ -f "$U/$X.service.d/10-lease-guard.conf" ] && grep -qx 'AssertPathExists=/srv/lease/ok' "$U/sala-web.service.d/10-lease-guard.conf" \
    && ok "the old drop-ins carried over to the new service and socket, the old ones kept" || bad "drop-ins: $(ls -R "$U" | grep -v migrated)"
[ -L "$PROD/web/.venv/bin/$X" ] && [ "$(readlink "$PROD/web/.venv/bin/$X")" = sala-web ] && ok "the old command linked to sala-web in the venv" || bad "old command: $(ls -l "$PROD/web/.venv/bin")"
rm -f "$PROD/web/.venv/bin/$X"   # a rebuilt venv has no link; the units are aliases now
: > "$FAKE_LOG"; deploy --web
[ -L "$PROD/web/.venv/bin/$X" ] && [ "$(readlink "$PROD/web/.venv/bin/$X")" = sala-web ] && ok "the next web step: the old command's link made again" || bad "link not remade: $(ls -l "$PROD/web/.venv/bin")"
[ "$rc" = 0 ] && [ "$(calls)" = "$WEB_CALLS" ] && ok "the next web step: the plain restart of sala-web.service" || bad "after migration: rc=$rc calls=$(calls) $out"
rm -rf "$U" "$HOME/.local/state" "$PROD/web/.venv"

[ "$fail" = 0 ] && echo "deploy: pass" || echo "deploy: FAIL"
exit $fail
