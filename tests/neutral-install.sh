#!/usr/bin/env bash
# Neutral install: sala installed from this checkout into an empty home, with no owner config at all, shows nothing of the first owner.
# tests/neutral-defaults.sh checks each default one by one; this suite does what a second person does on a new machine and reads what
# comes out, so a first-owner name that slips into a message, a help line, a printed setting or a web page fails here.
#   1. install.sh runs against a scratch HOME (and XDG dirs inside it): it links `salamander` and `sala`, seeds the config from
#      config.example and compact.tsv, is idempotent (a second run leaves an edited config alone), and `--web` writes the three
#      systemd user units into the scratch dir. systemctl, loginctl and tmux are stubs on PATH that log any call and fail: the suite
#      asserts at the end that nothing called them (no user systemd manager, no tmux server is touched).
#   2. read-only commands of the installed `sala` run in that environment: --help, the help of lane, op, job, note and question, `lane
#      --list` and `config` (the printed settings: the neutral values are asserted, not only scanned).
#   3. the sala-web web app (web/src/sala_web/app.py) is built with the test client over scratch directories under the same environment, and
#      /api/config, the index page, the sessions page and the manifest are read. It needs the web app's Python environment (web/.venv, or
#      uv with its cache); with neither the web part is reported as skipped, not passed.
#   Every output is matched against the first owner's private words (names, initials, domain, machines, organization, time zone, scope
#   names), which this file itself does not hold: they are the deny source clean_text.py reads ($CLEAN_TEXT_DENY, else the file
#   $XDG_CONFIG_HOME/salamander/clean-text-deny, one regex per line). Only counts and line numbers are printed, never a pattern. A
#   machine with no deny source skips those scans with one notice; the install and the neutral values are still asserted.
#   The web part pins the host name (the test machine's own name is not a leak) and TZ=Etc/UTC.
# Isolated HOME in a temp folder (locked while the suite runs, removed at the end); the real ~/.config is read only for the deny
# lists, and its sala config must have the same size and time after the run.
# Usage: bash tests/neutral-install.sh   (exit 0 = pass; a few seconds)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
REAL_HOME=${HOME:-}
REAL_CFG=${XDG_CONFIG_HOME:-$REAL_HOME/.config}
REAL_UV_CACHE=${UV_CACHE_DIR:-${XDG_CACHE_HOME:-$REAL_HOME/.cache}/uv}
T=""
trap '[ -n "$T" ] && rm -rf "$T"' EXIT
T=$(mktemp -d "${TMPDIR:-/tmp}/sala-neutral.XXXXXX")
exec 8< "$T"; flock -n 8 2>/dev/null   # systemd-tmpfiles' ageing skips a directory held with flock
H="$T/home"; STUB="$T/stub"; OUT="$T/out"; mkdir -p "$H" "$STUB" "$OUT" "$T/run" "$T/tmux"
BASHDIR=$(dirname "$(command -v bash)")
SYSPATH="$BASHDIR:/usr/bin:/bin"

# the first owner's words (names, initials, domain, machines, organization, reseller, time zone) are not listed here (naming them
# would publish them): they are the lines of the deny source clean_text.py reads, loaded once below and matched the way it matches.

# the real config's identity before the run, to prove the suite never wrote to it
real_cfg_id() { stat -c '%Y %s' "$REAL_CFG/salamander/config" 2>/dev/null || echo none; }
BEFORE=$(real_cfg_id)

# stubs: any call is logged and fails
for b in tmux systemctl loginctl; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/stub.log"\nexit 1\n' "$b" "$T" > "$STUB/$b"
    chmod +x "$STUB/$b"
done

# sx <command…> — run a command in the bare environment: scratch HOME and XDG dirs, stubs first on PATH, no SALA_* variable, no tmux
sx() {
    env -i HOME="$H" PATH="$STUB:$H/.local/bin:$SYSPATH" XDG_CONFIG_HOME="$H/.config" XDG_STATE_HOME="$H/.local/state" \
        XDG_RUNTIME_DIR="$T/run" TMUX_TMPDIR="$T/tmux" LC_ALL=C TERM=dumb TZ=Etc/UTC "$@" </dev/null
}

# norm <file> — the checkout's path and the scratch paths replaced, in place (a checkout under the owner's name is not a leak of the product)
norm() { sed -i -e "s|$ROOT|<ROOT>|g" -e "s|$T|<TMP>|g" "$1"; }

# the deny source (tests/deny_source.py, read before HOME changes), counted and never printed; none on this machine: the scans are skipped, with a notice
deny_load "$T/deny"

# scan <label> <file> — no line of the file hits the deny source (only counts and line numbers are printed, never a pattern or its match)
scan() {
    local label=$1 f=$2 n
    norm "$f"
    deny_have || return 0
    n=$(deny_count "$f")
    [ "$n" = 0 ] && ok "$label: no deny-source hit" || bad "$label: $n line(s) hit the deny source (lines $(deny_at "$f"))"
}

echo "== install.sh into an empty home"
sx bash "$ROOT/install.sh" > "$OUT/install.txt" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "install.sh exits 0 with no config, no ~/.claude, no claude binary" || bad "install.sh rc=$rc: $(tail -3 "$OUT/install.txt")"
[ "$(readlink "$H/.local/bin/salamander")" = "$ROOT/bin/salamander" ] && [ "$(readlink "$H/.local/bin/sala")" = "$ROOT/bin/salamander" ] && ok "salamander and sala link to this checkout's bin/salamander" || bad "links: $(ls -l "$H/.local/bin" 2>&1 | tail -2 | paste -sd'|')"
cmp -s "$ROOT/config.example" "$H/.config/salamander/config" && ok "the config is a copy of config.example" || bad "the seeded config differs from config.example"
[ -s "$H/.local/state/salamander/compact.tsv" ] && ok "compact.tsv is seeded" || bad "no compact.tsv"
grep -q '^[^#[:space:]]' "$H/.config/salamander/config" && bad "the seeded config sets a value of its own: $(grep -c '^[^#[:space:]]' "$H/.config/salamander/config") line(s)" || ok "the seeded config has no active line (every setting is commented out)"
scan "install output" "$OUT/install.txt"
scan "seeded config" "$H/.config/salamander/config"
printf '# edited by the new owner\n' >> "$H/.config/salamander/config"
sx bash "$ROOT/install.sh" > "$OUT/install2.txt" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -qx '# edited by the new owner' "$H/.config/salamander/config" && ok "a second run is idempotent: the edited config is kept" || bad "second install rc=$rc, edited line kept: $(grep -c 'edited by the new owner' "$H/.config/salamander/config")"
sx bash "$ROOT/install.sh" --web > "$OUT/install-web.txt" 2>&1; rc=$?
[ "$rc" = 0 ] && ok "install.sh --web exits 0" || bad "install.sh --web rc=$rc: $(tail -3 "$OUT/install-web.txt")"
U="$H/.config/systemd/user"; n=0
for u in sala-web.socket sala-web.service sala-web-ttyd.service; do [ -s "$U/$u" ] && n=$((n + 1)); done
[ "$n" = 3 ] && ok "the three web units are written into the scratch systemd user dir" || bad "web units written: $n of 3 ($(ls "$U" 2>&1 | paste -sd' '))"
scan "install --web output" "$OUT/install-web.txt"
for u in sala-web.socket sala-web.service sala-web-ttyd.service; do [ -s "$U/$u" ] && { cp "$U/$u" "$OUT/unit-$u"; scan "unit $u" "$OUT/unit-$u"; }; done

echo "== the installed sala: help and read-only commands"
runsala() {   # <name> <args…> — output in $OUT/<name>.txt, exit code in $rc
    local name=$1; shift
    sx sala "$@" > "$OUT/$name.txt" 2>&1; rc=$?
}
runsala help --help
[ "$rc" = 0 ] && [ "$(wc -l < "$OUT/help.txt")" -gt 50 ] && ok "sala --help prints the usage (exit 0)" || bad "sala --help: rc=$rc, $(wc -l < "$OUT/help.txt") lines"
scan "sala --help" "$OUT/help.txt"
for v in lane op job note question; do
    runsala "help-$v" "$v" --help
    [ -s "$OUT/help-$v.txt" ] && ! grep -q 'unknown subcommand' "$OUT/help-$v.txt" && ok "sala $v --help prints its usage (exit $rc)" || bad "sala $v --help: rc=$rc: $(head -2 "$OUT/help-$v.txt" | paste -sd'|')"
    scan "sala $v --help" "$OUT/help-$v.txt"
done
runsala lanelist lane --list
[ "$rc" = 0 ] && [ -s "$OUT/lanelist.txt" ] && ok "sala lane --list prints the lane fields (exit 0)" || bad "sala lane --list: rc=$rc: $(head -3 "$OUT/lanelist.txt" | paste -sd'|')"
scan "sala lane --list" "$OUT/lanelist.txt"
runsala config config
[ "$rc" = 0 ] && ok "sala config exits 0" || bad "sala config rc=$rc"
scan "sala config" "$OUT/config.txt"
for kv in 'SALA_SHELL_SESSION +sala-shell$' 'SALA_OWNER_NAME +the owner$' 'SALA_TZ *$' 'SALA_SCOPES *$' 'SALA_DEFAULT_SCOPE *$' 'SALA_BRAND_SUFFIX *$' 'SALA_HELP_SESSION *$' 'SALA_BACK_CWD *$' \
          'SALA_JOB_LANE +subscription-1$' 'SALA_LANE_BEDROCK_PROFILE *$' 'SALA_LANE_MAX_ORG *$' 'SALA_STACKSHOT_WEB *$' 'SALA_SESSION_URL *$' 'SALA_FLEET_HOSTS *$' 'SALA_MASTER *$'; do
    grep -qE -- "^$kv" "$OUT/config.txt" && ok "sala config: ${kv%% *} is ${kv#* }" || bad "sala config: expected '$kv', got '$(grep -E "^${kv%% *}( |$)" "$OUT/config.txt" | head -1)'"
done

echo "== the web app on the same scratch home"
cat > "$T/web_check.py" <<'PYEOF'
import socket, sys
from pathlib import Path
from starlette.testclient import TestClient
from sala_web.app import create_app
from sala_web.config import Settings

socket.gethostname = lambda: "box-a"   # the test machine's own name is not what is under test
root, out = Path(sys.argv[1]), Path(sys.argv[2])
claude = root / "claude"
(claude / "sessions").mkdir(parents=True)
(claude / "projects").mkdir()
settings = Settings(socket=root / "s.sock", state_dir=root / "state", claude_dir=claude,
                    tmux_socket_name="sala-neutral-unused", roles_cmd=["false"])
client = TestClient(create_app(settings))
bad = 0
for name, path in (("config", "/api/config"), ("index", "/"), ("sessions", "/sessions"), ("manifest", "/manifest.webmanifest")):
    r = client.get(path)
    (out / ("web-%s.txt" % name)).write_text(r.text, encoding="utf-8")
    print("%s %s" % (path, r.status_code))
    bad += r.status_code != 200
sys.exit(1 if bad else 0)
PYEOF
WEBPY=""
if [ -x "$ROOT/web/.venv/bin/python" ]; then WEBPY="$ROOT/web/.venv/bin/python"; fi
if [ -n "$WEBPY" ]; then
    mkdir -p "$T/webroot"
    sx env UV_CACHE_DIR="$REAL_UV_CACHE" "$WEBPY" -I "$T/web_check.py" "$T/webroot" "$OUT" > "$OUT/web-run.txt" 2>&1; rc=$?
elif command -v uv >/dev/null 2>&1; then
    mkdir -p "$T/webroot"
    sx env UV_CACHE_DIR="$REAL_UV_CACHE" PYTHONPATH="$ROOT/web/src" "$(command -v uv)" run --frozen --offline --project "$ROOT/web" python "$T/web_check.py" "$T/webroot" "$OUT" > "$OUT/web-run.txt" 2>&1; rc=$?
elif [ -n "${CI:-}" ]; then
    rc=nouv
else
    rc=skip
fi
if [ "$rc" = skip ]; then
    echo "  skip the web app: no web/.venv and no uv on this machine (the web CI job runs the app's own tests)"
elif [ "$rc" = nouv ]; then
    bad "the web check cannot run: CI is set and the machine has neither web/.venv nor uv (a skip here would hide the web part)"
elif [ "$rc" != 0 ]; then
    bad "the web check did not run through (rc=$rc): $(tail -4 "$OUT/web-run.txt" | cut -c1-200 | paste -sd'|')"
else
    ok "the web app answers /api/config, /, /sessions and /manifest.webmanifest with 200"
    for kv in '"shellSession":"sala-shell"' '"brand":""' '"scopes":\[\]' '"defaultScope":""' '"timezone":""' '"host":"box-a"'; do
        grep -qE -- "$kv" "$OUT/web-config.txt" && ok "/api/config has $kv" || bad "/api/config lacks $kv: $(cut -c1-300 "$OUT/web-config.txt")"
    done
    ! grep -q -- 'sp-help\|{{help}}\|<!--help-->' "$OUT/web-index.txt" && ok "with no SALA_HELP_SESSION the page has no Get Help chip and no raw placeholder" || bad "the served page carries the Get Help chip or a placeholder"
    for p in config index sessions manifest; do scan "web /$p" "$OUT/web-$p.txt"; done
fi

echo "== nothing outside the scratch home was touched"
[ ! -s "$T/stub.log" ] && ok "no call to tmux, systemctl or loginctl" || bad "stubbed commands were called: $(paste -sd'|' < "$T/stub.log" | cut -c1-300)"
[ "$(real_cfg_id)" = "$BEFORE" ] && ok "the real sala config is unchanged" || bad "the real sala config changed during the run"

[ "$fail" = 0 ] && echo "neutral-install: pass" || echo "neutral-install: FAIL"
exit "$fail"
