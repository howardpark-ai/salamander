#!/usr/bin/env bash
# `install.sh --web` and the web UI's ttyd pieces (web/contrib/sala-web-ttyd.service, web/contrib/sala-web-ttyd-attach; the recipe is docs/web-proxy.md, which no suite opens).
# Checked: a plain install.sh installs no unit and points at --web; --web writes the three units into $XDG_CONFIG_HOME/systemd/user
# (else ~/.config/systemd/user), mode 644, starts and enables nothing; a checkout under $HOME is written as %h/<path>, one outside it
# as an absolute path, and a path with a character a unit cannot carry safely is refused with nothing written; a second run changes
# nothing; an unknown option exits 2; the ttyd unit keeps the settings the web UI relies on (a unix socket in a directory of its own,
# --base-path /tty, --url-arg, --check-origin) and names no owner value; the attach script attaches an existing session and nothing
# else, on a private tmux server (`tmux -L`), its name checked before tmux sees it. The migration from the units' old name
# (lib/webunits.sh) runs against a fake systemctl and a fake uv on PATH that only log: the old units found by what they are, the
# new ones installed, the old ones stopped, disabled and aliased, the state moved (or both kept), the old socket paths named in a
# drop-in, the old units' drop-ins (service, socket, ttyd) copied to the new units unless a file of that name is there (then left, and
# said), the old drop-in directories kept, the old command linked to sala-web in the venv (never over a path that exists), the new
# units enabled and started as the old ones were, and a second run doing nothing; SALA_WEB_SOCKET pins ListenStream. When both state
# directories exist the entries of the old one are merged into the new one with the web service stopped (the user's files from the
# old one, the displaced new ones kept beside them, the caches the new ones, one line per move, the leftovers said), on a migration
# and on an install migrated before; a second run changes nothing.
# The temporary folder is made first under a trap, locked for the run, and removed on the way out, pass or fail. tmux is touched on
# one private socket only (-L sala-webinstall-$$ -f /dev/null), and the only kill is that server's own `kill-server`, after which its socket file is removed.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib.sh"
T=""; TSOCK="sala-webinstall-$$"
cleanup() {
    [ -n "$TSOCK" ] && command -v tmux >/dev/null && tmux -L "$TSOCK" -f /dev/null kill-server 2>/dev/null
    [ -n "$TSOCK" ] && tmux_socket_rm "$TSOCK"   # tmux 3.6 keeps the socket file after kill-server
    [ -n "$T" ] && rm -rf "$T"
}
trap cleanup EXIT
T=$(mktemp -d "${TMPDIR:-/tmp}/sala-webinstall.XXXXXX")
exec 8< "$T"; flock -n 8 2>/dev/null   # systemd-tmpfiles' ageing skips a directory held with flock
fail=0
deny_load "$T/deny"   # the deny source is read before HOME changes (XDG_CONFIG_HOME is unset just below)
ORIG_XRD="${XDG_RUNTIME_DIR:-}"
unset XDG_CONFIG_HOME XDG_STATE_HOME XDG_RUNTIME_DIR BIN_DIR TMUX

# a copy of the checkout's install inputs under a fake HOME, so %h/<path> is what --web writes
H="$T/home"; mkdir -p "$H/sala"
for f in install.sh config.example bin lib contrib/compact.tsv web/contrib; do mkdir -p "$H/sala/$(dirname "$f")"; cp -R "$ROOT/$f" "$H/sala/$f"; done
run() { HOME="$H" BIN_DIR="$H/bin" "$@"; }   # install.sh with the fake HOME
U="$H/.config/systemd/user"

echo "== plain install.sh: no unit, a pointer to --web"
out=$(run bash "$H/sala/install.sh" 2>&1); rc=$?
[ "$rc" = 0 ] && [ ! -e "$U" ] && [[ $out == *"install.sh --web"* ]] && ok "no unit written, --web named" || bad "plain install (rc=$rc): $out"

echo "== install.sh --web: three units, %h-relative, nothing started"
out=$(run bash "$H/sala/install.sh" --web 2>&1); rc=$?
[ "$rc" = 0 ] && ok "exit 0" || bad "--web exit $rc: $out"
for u in sala-web.socket sala-web.service sala-web-ttyd.service; do
    [ -f "$U/$u" ] && [ "$(stat -c %a "$U/$u")" = 644 ] && ok "$u installed, mode 644" || bad "$u missing or wrong mode"
done
grep -q '^ExecStart=%h/sala/web/.venv/bin/sala-web$' "$U/sala-web.service" && ok "sala-web.service runs from the checkout under %h" || bad "sala-web.service ExecStart: $(grep ^ExecStart "$U/sala-web.service")"
grep -q 'sala-web-ttyd-attach$' "$U/sala-web-ttyd.service" && grep -q ' %h/sala/web/contrib/sala-web-ttyd-attach$' "$U/sala-web-ttyd.service" && ok "ttyd unit runs the attach script from the checkout under %h" || bad "ttyd ExecStart: $(grep -A1 ^ExecStart "$U/sala-web-ttyd.service")"
! grep -q '^ExecStart=.*%h/salamander\|^  .*%h/salamander' "$U"/sala-web*.* && ok "no %h/salamander left in an installed ExecStart" || bad "%h/salamander left in an ExecStart"
[ -z "$(find "$U" -name '.*' -type f)" ] && ok "no temporary file left beside the units" || bad "leftover: $(ls -A "$U")"
[ ! -e "$H/.config/systemd/user/default.target.wants" ] && ok "nothing enabled" || bad "a wants directory appeared"
[[ $out == *"enable --now sala-web.socket sala-web.service sala-web-ttyd.service"* ]] && [[ $out == *"docs/web-proxy.md"* ]] && ok "the next commands and the proxy doc are printed" || bad "output: $out"

echo "== a second run changes nothing"
sum1=$(cd "$U" && sha256sum sala-web*); run bash "$H/sala/install.sh" --web >/dev/null 2>&1; sum2=$(cd "$U" && sha256sum sala-web*)
[ "$sum1" = "$sum2" ] && ok "same files" || bad "files changed on a second run"

echo "== XDG_CONFIG_HOME is honoured"
X="$T/xdg"; out=$(XDG_CONFIG_HOME="$X" run bash "$H/sala/install.sh" --web 2>&1)
[ -f "$X/systemd/user/sala-web-ttyd.service" ] && ok "units under \$XDG_CONFIG_HOME/systemd/user" || bad "XDG: $out"

echo "== a checkout outside HOME: absolute path"
O="$T/outside/sala"; mkdir -p "$O"; for f in install.sh config.example bin lib contrib/compact.tsv web/contrib; do mkdir -p "$O/$(dirname "$f")"; cp -R "$ROOT/$f" "$O/$f"; done
H2="$T/home2"; mkdir -p "$H2"
HOME="$H2" BIN_DIR="$H2/bin" bash "$O/install.sh" --web >/dev/null 2>&1
grep -q "^ExecStart=$O/web/.venv/bin/sala-web\$" "$H2/.config/systemd/user/sala-web.service" && ok "absolute ExecStart" || bad "outside: $(grep ^ExecStart "$H2/.config/systemd/user/sala-web.service" 2>&1)"

echo "== a path a unit cannot carry safely is refused, nothing written"
Q="$T/we ird/sala"; mkdir -p "$Q"; for f in install.sh config.example bin lib contrib/compact.tsv web/contrib; do mkdir -p "$Q/$(dirname "$f")"; cp -R "$ROOT/$f" "$Q/$f"; done
H3="$T/home3"; mkdir -p "$H3"
out=$(HOME="$H3" BIN_DIR="$H3/bin" bash "$Q/install.sh" --web 2>&1); rc=$?
[ "$rc" = 1 ] && [ ! -e "$H3/.config/systemd/user" ] && ok "exit 1, no unit folder" || bad "odd path (rc=$rc): $out"
for odd in 'pc%t' 'dl$x'; do   # a % is a unit specifier and a $ an environment reference in an ExecStart line
    Q2="$T/$odd/sala"; mkdir -p "$Q2"; for f in install.sh config.example bin lib contrib/compact.tsv web/contrib; do mkdir -p "$Q2/$(dirname "$f")"; cp -R "$ROOT/$f" "$Q2/$f"; done
    out=$(HOME="$H3" BIN_DIR="$H3/bin" bash "$Q2/install.sh" --web 2>&1); rc=$?
    [ "$rc" = 1 ] && [ ! -e "$H3/.config/systemd/user" ] && ok "a path with ${odd//[A-Za-z]/}: exit 1, nothing written" || bad "path $odd (rc=$rc): $out"
done

echo "== a failed write: no success, no temporary file left"
H4="$T/home4"; mkdir -p "$H4/.config/systemd/user"; chmod 555 "$H4/.config/systemd/user"   # a folder the user cannot write to
if [ -w "$H4/.config/systemd/user" ]; then
    ok "running as a user that can write anywhere (root): the failed-write case is skipped"
else
    out=$(HOME="$H4" BIN_DIR="$H4/bin" bash "$H/sala/install.sh" --web 2>&1); rc=$?
    [ "$rc" = 1 ] && [[ $out == *"install.sh --web: cannot write"* ]] && ok "exit 1 with a message" || bad "failed write (rc=$rc): $(printf '%s' "$out" | tail -3)"
    [ -z "$(find "$H4/.config/systemd/user" -name '.sala-web*' 2>/dev/null)" ] && ok "no temporary file left" || bad "leftover: $(ls -A "$H4/.config/systemd/user")"
    [[ $out != *"enable --now sala-web.socket"* ]] && ok "no next-steps text after a failure" || bad "success text printed after a failure"
fi
chmod 755 "$H4/.config/systemd/user"   # so the cleanup can remove it

echo "== an unknown option"
out=$(run bash "$H/sala/install.sh" --bogus 2>&1); rc=$?
[ "$rc" = 2 ] && ok "exit 2" || bad "--bogus exit $rc: $out"

echo "== the migration from the units' old name (lib/webunits.sh), with a fake systemctl and a fake uv"
# The old units are made here under a neutral stand-in name; the migration finds them by what they are, not by name.
M="$T/home-mig"; mkdir -p "$M/sala"
for f in install.sh config.example bin lib contrib/compact.tsv web/contrib; do mkdir -p "$M/sala/$(dirname "$f")"; cp -R "$ROOT/$f" "$M/sala/$f"; done
FB="$T/fakebin"; mkdir -p "$FB"; FLOG="$T/fake-calls"
cat > "$FB/systemctl" <<'FAKE'
#!/bin/bash
echo "systemctl $*" >> "$FAKE_LOG"
case " $* " in
    *" is-enabled "*|*" is-active "*) for u in $FAKE_ON; do [[ " $* " == *" $u "* ]] && exit 0; done; exit 1 ;;
esac
exit 0
FAKE
cat > "$FB/uv" <<'FAKE'
#!/bin/bash
echo "uv $* (in $PWD)" >> "$FAKE_LOG"
mkdir -p .venv/bin && printf '#!/bin/sh\n' > .venv/bin/sala-web && chmod +x .venv/bin/sala-web
FAKE
chmod +x "$FB/systemctl" "$FB/uv"
MU="$M/.config/systemd/user"; X=legacy-ui
mkunits() {   # the old install: the three units as an install.sh --web of the old name wrote them, a drop-in, a state directory
    rm -rf "$MU" "$M/.local/state"; mkdir -p "$MU/$X.service.d" "$MU/$X.socket.d" "$MU/$X-ttyd.service.d" "$M/.local/state/$X/uploads"
    printf '[Unit]\nRequires=%s.socket\nAfter=%s.socket\n[Service]\nExecStart=%%h/sala/web/.venv/bin/%s\n[Install]\nWantedBy=default.target\n' "$X" "$X" "$X" > "$MU/$X.service"
    printf '[Socket]\nListenStream=%%t/%s/%s.sock\n' "$X" "$X" > "$MU/$X.socket"
    printf '[Service]\nRuntimeDirectory=%s-ttyd\nExecStart=/usr/bin/ttyd --interface %%t/%s-ttyd/ttyd.sock --base-path /tty \\\n  %%h/sala/web/contrib/%s-ttyd-attach\n' "$X" "$X" "$X" > "$MU/$X-ttyd.service"
    printf '[Service]\nEnvironment=A=1\n' > "$MU/$X.service.d/local.conf"
    printf '[Unit]\nAssertPathExists=/srv/lease/ok\n' > "$MU/$X.service.d/10-lease-guard.conf"; printf '[Unit]\nAssertPathExists=/srv/lease/ok\n' > "$MU/$X.socket.d/10-lease-guard.conf"
    printf '[Service]\nNice=5\n' > "$MU/$X-ttyd.service.d/20-nice.conf"; echo note > "$MU/$X.service.d/not-a-dropin.txt"
    echo '{"a":1}' > "$M/.local/state/$X/read-state.json"
    # an unrelated unit of the user's: a web venv of another project, no matching socket; never taken for the old web UI
    printf '[Service]\nExecStart=%%h/other/web/.venv/bin/other\n' > "$MU/other.service"
}
mrun() { : > "$FLOG"; out=$(HOME="$M" BIN_DIR="$M/bin" PATH="$FB:$PATH" FAKE_LOG="$FLOG" FAKE_ON="$X.service $X.socket $X-ttyd.service" bash "$M/sala/install.sh" "$@" 2>&1); rc=$?; }
mkunits; mrun
[ "$rc" = 0 ] && ok "a plain install.sh on an install with the old units: exit 0" || bad "migration rc=$rc: $out"
for u in sala-web.socket sala-web.service sala-web-ttyd.service; do [ -f "$MU/$u" ] && [ ! -L "$MU/$u" ] || bad "$u not installed"; done
grep -q '^ExecStart=%h/sala/web/.venv/bin/sala-web$' "$MU/sala-web.service" && ok "the new units installed from the checkout" || bad "new ExecStart: $(grep ^ExecStart "$MU/sala-web.service" 2>&1)"
for p in "$X.service:sala-web.service" "$X.socket:sala-web.socket" "$X-ttyd.service:sala-web-ttyd.service"; do
    o=${p%%:*}; n=${p#*:}
    [ -L "$MU/$o" ] && [ "$(readlink "$MU/$o")" = "$n" ] && [ -f "$MU/$o.migrated" ] && ok "$o kept as $o.migrated and made an alias of $n" || bad "$o: $(ls -l "$MU" | grep "$o")"
    grep -qx "systemctl --user stop $o" "$FLOG" && grep -qx "systemctl --user disable --quiet $o" "$FLOG" && ok "$o stopped and disabled" || bad "$o calls: $(cat "$FLOG")"
done
grep -q "^ExecStart=%h/other/web/.venv/bin/other" "$MU/other.service" && ! grep -q 'other.service' "$FLOG" && ok "an unrelated unit is left alone" || bad "other.service touched"
[ -f "$M/.local/state/sala-web/read-state.json" ] && [ -d "$M/.local/state/sala-web/uploads" ] && [ ! -e "$M/.local/state/$X" ] && ok "the old state directory moved to the new one" || bad "state: $(ls "$M/.local/state")"
D="$MU/sala-web.service.d/old-socket-path.conf"
grep -qx "Environment=SALA_WEB_COMPAT_SOCKET=%t/$X/$X.sock" "$D" && grep -qx "Environment=SALA_WEB_COMPAT_TTYD_SOCKET=%t/$X-ttyd/ttyd.sock" "$D" \
    && grep -qx "ExecStartPre=-/bin/mkdir -p -m 0700 %t/$X" "$D" && grep -qx "ExecStartPre=-/bin/mkdir -p -m 0700 %t/$X-ttyd" "$D" && grep -qx '\[Service\]' "$D" \
    && ok "the drop-in names the old socket paths and recreates their directories" || bad "drop-in: $(cat "$D" 2>&1)"
seq=$(grep -n -e 'daemon-reload' -e 'enable --quiet sala-web' -e 'start sala-web' -e "stop $X.service" "$FLOG" | cut -d: -f2- | paste -sd'|')
[[ $seq == "systemctl --user stop $X.service|systemctl --user daemon-reload|systemctl --user enable --quiet sala-web.service sala-web-ttyd.service sala-web.socket|systemctl --user start sala-web.service sala-web-ttyd.service sala-web.socket" ]] \
    && ok "old stopped first, then daemon-reload, the new units enabled and started as the old ones were" || bad "order: $seq"
grep -q "^uv sync --frozen (in $M/sala/web)\$" "$FLOG" && ok "the venv synced first (it had no sala-web command)" || bad "uv: $(cat "$FLOG")"
[[ $out == *"drop-in carried over: $MU/$X.service.d/10-lease-guard.conf"* ]] && [[ $out == *"migrated to sala-web"* ]] && ok "the drop-ins carried over said, the migration said" || bad "output: $out"
cmpdrop() { cmp -s "$MU/$X.$1.d/$2" "$MU/sala-web.$1.d/$2"; }
cmpdrop service 10-lease-guard.conf && cmpdrop socket 10-lease-guard.conf && cmpdrop service local.conf && cmp -s "$MU/$X-ttyd.service.d/20-nice.conf" "$MU/sala-web-ttyd.service.d/20-nice.conf" \
    && grep -qx 'AssertPathExists=/srv/lease/ok' "$MU/sala-web.service.d/10-lease-guard.conf" "$MU/sala-web.socket.d/10-lease-guard.conf" \
    && ok "every *.conf of the old service, socket and ttyd drop-ins is copied to the new unit's directory" || bad "drop-ins: $(ls -R "$MU" 2>&1 | grep -v migrated)"
[ ! -e "$MU/sala-web.service.d/not-a-dropin.txt" ] && [ -f "$MU/$X.service.d/10-lease-guard.conf" ] && [ -f "$MU/$X.socket.d/10-lease-guard.conf" ] && [ -f "$MU/$X-ttyd.service.d/20-nice.conf" ] \
    && ok "only *.conf copied, the old drop-in directories kept" || bad "old drop-in dirs: $(ls -R "$MU" 2>&1)"
[ -L "$M/sala/web/.venv/bin/$X" ] && [ "$(readlink "$M/sala/web/.venv/bin/$X")" = sala-web ] && [[ $out == *"/web/.venv/bin/$X -> sala-web"* ]] \
    && ok "the old command is a link to sala-web in the venv, said" || bad "old command: $(ls -l "$M/sala/web/.venv/bin" 2>&1) $out"
dsum1=$(cd "$MU" && find . -path '*.d/*' -type f | sort | xargs sha256sum | sha256sum); lsum1=$(readlink "$M/sala/web/.venv/bin/$X")
mrun --web
dsum2=$(cd "$MU" && find . -path '*.d/*' -type f | sort | xargs sha256sum | sha256sum)
[ "$dsum1" = "$dsum2" ] && [ "$(readlink "$M/sala/web/.venv/bin/$X")" = "$lsum1" ] && [[ $out != *"carried over"* ]] && [[ $out != *"-> sala-web"* ]] && ok "a second run changes no drop-in and no link, and says nothing of them" || bad "second run changed drop-ins or the link: $out"
[ "$rc" = 0 ] && ! grep -q -e ' stop ' -e ' start ' -e 'uv ' "$FLOG" && [[ $out == *"enable --now sala-web.socket"* ]] && [[ $out != *migrat* ]] \
    && ok "a second run (install.sh --web): nothing migrated again, the usual next steps" || bad "second run rc=$rc calls=$(cat "$FLOG") $out"
# the venv was rebuilt (the link gone) while the old units are only aliases: the next --web step makes it again; a file in its place is left
rm -f "$M/sala/web/.venv/bin/$X"; mrun --web
[ -L "$M/sala/web/.venv/bin/$X" ] && [ "$(readlink "$M/sala/web/.venv/bin/$X")" = sala-web ] && ok "install.sh --web, the old units now aliases: the old command's link made again" || bad "link not remade: $(ls -l "$M/sala/web/.venv/bin") $out"
rm -f "$M/sala/web/.venv/bin/$X"; printf '#!/bin/sh\n' > "$M/sala/web/.venv/bin/$X"; mrun --web
[ ! -L "$M/sala/web/.venv/bin/$X" ] && [ -f "$M/sala/web/.venv/bin/$X" ] && ok "a path that exists is left as it is" || bad "existing old-command path replaced"
rm -f "$M/sala/web/.venv/bin/$X"
mkunits; mkdir -p "$M/.local/state/sala-web"; echo new > "$M/.local/state/sala-web/keep"
# a same-name drop-in already in the new directory is not overwritten
mkdir -p "$MU/sala-web.service.d"; printf '[Service]\nEnvironment=KEEP=1\n' > "$MU/sala-web.service.d/local.conf"
: > "$FLOG"; out=$(HOME="$M" BIN_DIR="$M/bin" PATH="$FB:$PATH" FAKE_LOG="$FLOG" FAKE_ON="" bash "$M/sala/install.sh" --web 2>&1); rc=$?
[ "$rc" = 0 ] && [ ! -e "$M/.local/state/$X" ] && [ "$(cat "$M/.local/state/sala-web/keep")" = new ] && [ -f "$M/.local/state/sala-web/read-state.json" ] && [ -d "$M/.local/state/sala-web/uploads" ] \
    && [[ $out == *"both $M/.local/state/$X and $M/.local/state/sala-web exist"* ]] && [[ $out == *"moved $M/.local/state/$X/read-state.json → $M/.local/state/sala-web/read-state.json"* ]] && [[ $out == *"$M/.local/state/$X is empty and removed"* ]] \
    && ok "both state directories exist: the old one's entries moved in, the new ones kept, the emptied old directory removed, all said" || bad "both states rc=$rc: $out"
[ "$(cat "$MU/sala-web.service.d/local.conf")" = "$(printf '[Service]\nEnvironment=KEEP=1')" ] && [[ $out == *"$MU/sala-web.service.d/local.conf exists"* ]] && cmpdrop service 10-lease-guard.conf \
    && ok "a same-name file in the new drop-in directory is not overwritten (said), the others are copied" || bad "same-name drop-in: $(cat "$MU/sala-web.service.d/local.conf") $out"
! grep -q -e 'enable --quiet sala' -e 'start sala' "$FLOG" && [[ $out == *"enabled: none; started: none"* ]] && ok "old units neither enabled nor running: the new ones are not started either" || bad "off: $(cat "$FLOG")"
echo "== both state directories exist (the new service ran before the move): merged, with the web service stopped"
SO="$M/.local/state/$X"; SN="$M/.local/state/sala-web"
mkboth() {   # the old directory of a real install, and a new one the new service had already written into
    mkunits; mkdir -p "$SN/uploads" "$SO/mandates" "$SO/uploads"
    echo old-prefs > "$SO/prefs.json"; echo old-uploadA > "$SO/uploads/a.png"; echo old-uploadDup > "$SO/uploads/dup.png"; echo old-mandate > "$SO/mandates/m1.md"
    echo old-board > "$SO/board-items.json"; echo old-quota-conflict > "$SO/quota-lane.json"; echo old-quota-only > "$SO/quota-other.json"; echo old-spend > "$SO/spend-scan.json"
    echo new-prefs > "$SN/prefs.json"; echo new-uploadB > "$SN/uploads/b.png"; echo new-uploadDup > "$SN/uploads/dup.png"
    echo new-board > "$SN/board-items.json"; echo new-quota-conflict > "$SN/quota-lane.json"
}
mkboth; : > "$FLOG"
out=$(HOME="$M" BIN_DIR="$M/bin" PATH="$FB:$PATH" FAKE_LOG="$FLOG" FAKE_ON="sala-web.service sala-web.socket" bash "$M/sala/install.sh" --web 2>&1); rc=$?
[ "$rc" = 0 ] && ok "exit 0" || bad "merge rc=$rc: $out"
[ "$(cat "$SN/prefs.json")" = old-prefs ] && [ "$(cat "$SN/read-state.json")" = '{"a":1}' ] && [ "$(cat "$SN/mandates/m1.md")" = old-mandate ] && [ "$(cat "$SN/uploads/a.png")" = old-uploadA ] \
    && [ "$(cat "$SN/uploads/b.png")" = new-uploadB ] && [ "$(cat "$SN/uploads/dup.png")" = old-uploadDup ] \
    && ok "the user's files: prefs, read-state, mandates and uploads moved in; the old one wins on a name both have; a new-only upload stays" || bad "user files: $(cd "$SN" && find . -type f | sort | xargs head -n1)"
[ "$(cat "$SN"/prefs.json.before-merge-*)" = new-prefs ] && [ "$(cat "$SN"/uploads/dup.png.before-merge-*)" = new-uploadDup ] \
    && ok "a new file the old one replaced is kept beside it, nothing lost" || bad "before-merge: $(cd "$SN" && find . -name '*before-merge*')"
[ "$(cat "$SN/board-items.json")" = new-board ] && [ "$(cat "$SN/quota-lane.json")" = new-quota-conflict ] && [ "$(cat "$SN/quota-other.json")" = old-quota-only ] && [ "$(cat "$SN/spend-scan.json")" = old-spend ] \
    && ok "caches: the new ones kept; a cache the new directory lacked moved in" || bad "caches: $(cd "$SN" && head -n1 board-items.json quota-lane.json quota-other.json spend-scan.json)"
[ "$(cat "$SO/board-items.json")" = old-board ] && [ "$(cat "$SO/quota-lane.json")" = old-quota-conflict ] && [ "$(ls "$SO" | wc -l)" = 2 ] \
    && ok "the old directory keeps only the caches the new ones outrank" || bad "left in old: $(ls -R "$SO")"
[[ $out == *"left in $SO (caches; sala-web uses the ones in $SN): board-items.json quota-lane.json"* ]] && [ "$(grep -c 'state: moved' <<<"$out")" = 7 ] \
    && [[ $out == *"state: moved $SO/prefs.json → $SN/prefs.json (the new one is kept as $SN/prefs.json.before-merge-"* ]] && [[ $out == *"state: moved $SO/uploads/a.png → $SN/uploads/a.png"* ]] \
    && ok "one line per moved entry, and a line naming what is left in the old directory" || bad "output ($(grep -c 'state: moved' <<<"$out") moved): $out"
seq=$(grep -n -e 'daemon-reload' -e 'stop sala-web' -e 'start sala-web' "$FLOG" | cut -d: -f2- | paste -sd'|')
[[ $seq == "systemctl --user stop sala-web.socket|systemctl --user stop sala-web.service|systemctl --user daemon-reload|systemctl --user start sala-web.socket sala-web.service" ]] \
    && ok "the new socket and service stopped before the merge, started again after the units were reloaded" || bad "order: $seq"
# nothing lost: every token written above is still in one of the two directories
lost=""; for tok in old-prefs old-uploadA old-uploadDup old-mandate old-board old-quota-conflict old-quota-only old-spend new-prefs new-uploadB new-uploadDup new-board new-quota-conflict; do
    grep -rqx "$tok" "$SN" "$SO" || lost="$lost $tok"; done
[ -z "$lost" ] && ok "nothing lost: every old and new file is still in one of the directories" || bad "lost:$lost"
sum1=$(cd "$M/.local/state" && find . -type f | sort | xargs sha256sum | sha256sum)
: > "$FLOG"; out=$(HOME="$M" BIN_DIR="$M/bin" PATH="$FB:$PATH" FAKE_LOG="$FLOG" FAKE_ON="sala-web.service sala-web.socket" bash "$M/sala/install.sh" --web 2>&1); rc=$?
sum2=$(cd "$M/.local/state" && find . -type f | sort | xargs sha256sum | sha256sum)
[ "$rc" = 0 ] && [ "$sum1" = "$sum2" ] && ok "a second run changes nothing" || bad "second run rc=$rc: $out"
# new-only: no old directory at all (old-only, the first move, is the "moved to the new one" case above)
rm -rf "$SO"; sum1=$(cd "$M/.local/state" && find . -type f | sort | xargs sha256sum | sha256sum)
: > "$FLOG"; out=$(HOME="$M" BIN_DIR="$M/bin" PATH="$FB:$PATH" FAKE_LOG="$FLOG" FAKE_ON="sala-web.service" bash "$M/sala/install.sh" --web 2>&1); rc=$?
sum2=$(cd "$M/.local/state" && find . -type f | sort | xargs sha256sum | sha256sum)
[ "$rc" = 0 ] && [ "$sum1" = "$sum2" ] && [[ $out != *"state:"* ]] && ! grep -q -e ' stop ' -e ' start ' "$FLOG" && ok "only the new directory: nothing touched, no unit stopped" || bad "new-only rc=$rc: $out $(cat "$FLOG")"
# the same merge inside the units' own migration (the old units still there): done before the new units are started
mkboth; : > "$FLOG"
out=$(HOME="$M" BIN_DIR="$M/bin" PATH="$FB:$PATH" FAKE_LOG="$FLOG" FAKE_ON="$X.service sala-web.service" bash "$M/sala/install.sh" 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(cat "$SN/prefs.json")" = old-prefs ] && [ "$(cat "$SN/board-items.json")" = new-board ] && [ -d "$SO" ] && [[ $out == *"migrated to sala-web"* ]] \
    && ok "the units' own migration merges the two directories too" || bad "migration merge rc=$rc: $out"
n_stop=$(grep -n 'stop sala-web.service' "$FLOG" | head -1 | cut -d: -f1); n_start=$(grep -n 'start sala-web' "$FLOG" | head -1 | cut -d: -f1); n_rel=$(grep -n daemon-reload "$FLOG" | head -1 | cut -d: -f1)
[ -n "$n_stop" ] && [ -n "$n_start" ] && [ "$n_stop" -lt "$n_rel" ] && [ "$n_rel" -lt "$n_start" ] && ok "the new service is stopped before the merge and started only after daemon-reload" || bad "calls: $(cat "$FLOG")"
# an install migrated by an earlier release (the old units are aliases now) with its old state directory still there: the install and the deploy's web step merge it
[ -L "$MU/$X.service" ] && ok "the old units are aliases now" || bad "not migrated: $(ls -l "$MU")"
rm -rf "$SO"; mkdir -p "$SO"; echo old-prefs2 > "$SO/prefs.json"; echo old-cache > "$SO/api-spend.json"; echo new-cache > "$SN/api-spend.json"; : > "$FLOG"
out=$(HOME="$M" BIN_DIR="$M/bin" PATH="$FB:$PATH" FAKE_LOG="$FLOG" FAKE_ON="sala-web.service" bash "$M/sala/install.sh" --web 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$(cat "$SN/prefs.json")" = old-prefs2 ] && compgen -G "$SN/prefs.json.before-merge-*" >/dev/null && [ "$(cat "$SO/api-spend.json")" = old-cache ] && [[ $out == *"moved $SO/prefs.json"* ]] \
    && [[ $out == *"left in $SO"*"api-spend.json"* ]] && ok "an install migrated before: the old state directory merged, the leftover said" || bad "late merge rc=$rc: $out"
[ "$(grep -c -e 'stop sala-web.service' "$FLOG")" = 1 ] && [ "$(tail -1 "$FLOG")" = "systemctl --user start sala-web.service" ] && ok "the running service stopped for the merge and started again" || bad "calls: $(cat "$FLOG")"

rm -rf "$MU"; out=$(HOME="$M" BIN_DIR="$M/bin" SALA_WEB_SOCKET=/srv/web/app.sock PATH="$FB:$PATH" FAKE_LOG="$FLOG" bash "$M/sala/install.sh" --web 2>&1); rc=$?
[ "$rc" = 0 ] && grep -qx 'ListenStream=/srv/web/app.sock' "$MU/sala-web.socket" && ok "SALA_WEB_SOCKET pins the socket unit's ListenStream" || bad "pin rc=$rc: $out $(grep ListenStream "$MU/sala-web.socket" 2>&1)"
out=$(HOME="$M" BIN_DIR="$M/bin" SALA_WEB_SOCKET='rel/a b.sock' PATH="$FB:$PATH" FAKE_LOG="$FLOG" bash "$M/sala/install.sh" --web 2>&1); rc=$?
[ "$rc" = 1 ] && [[ $out == *"SALA_WEB_SOCKET"* ]] && ok "a relative SALA_WEB_SOCKET is refused" || bad "bad pin rc=$rc: $out"

echo "== the ttyd unit"
S="$ROOT/web/contrib/sala-web-ttyd.service"
execline=$(awk '/^ExecStart=/ {f=1} f {print} f && !/\\$/ {exit}' "$S" | tr '\n' ' ')
for want in '--interface %t/sala-web-ttyd/ttyd.sock' '--base-path /tty' '--url-arg' '--check-origin' '--writable'; do
    [[ $execline == *" $want "* ]] && ok "ExecStart has $want" || bad "ExecStart lacks $want"
done
grep -q '^RuntimeDirectory=sala-web-ttyd$' "$S" && ok "its own runtime directory (sala-web's is not touched)" || bad "RuntimeDirectory"
grep -q '^UMask=0077$' "$S" && ok "UMask 0077" || bad "UMask"
UNITFILES=("$ROOT"/web/contrib/sala-web.socket "$ROOT"/web/contrib/sala-web.service "$ROOT"/web/contrib/sala-web-ttyd.service "$ROOT/web/contrib/sala-web-ttyd-attach")
grep -qiE 'an access proxy|/run/user/[0-9]|board#|production checkout' "${UNITFILES[@]}" && bad "a board id, a runtime path or a deployment note in the three units or the attach script" || ok "no board id, hard-coded runtime path or deployment note in the three units or the attach script"
if deny_have; then   # the owner's names, hosts and paths are the deny source's lines (tests/deny_source.py), not written here
    n=0; for f in "${UNITFILES[@]}"; do n=$((n + $(deny_count "$f"))); done
    [ "$n" = 0 ] && ok "no deny-source hit in the three units or the attach script" || bad "$n deny-source hit line(s) in the three units or the attach script"
fi
if command -v systemd-analyze >/dev/null; then
    # against the user manager of whoever runs the suite (the fake HOME has none); a runner without one skips it
    out=$(XDG_RUNTIME_DIR="$ORIG_XRD" systemd-analyze --user verify "$S" 2>&1 | grep -v 'not executable\|No such file')
    case "$out" in
        *"Failed to"*) ok "systemd-analyze verify: no user manager here, skipped" ;;
        "") ok "systemd-analyze verify: no complaint about the ttyd unit" ;;
        *) bad "verify: $out" ;;
    esac
fi

echo "== the attach script, on a private tmux server"
if command -v tmux >/dev/null; then
    A="$ROOT/web/contrib/sala-web-ttyd-attach"
    [ -x "$A" ] && ok "executable" || bad "not executable"
    tmux -L "$TSOCK" -f /dev/null new-session -d -s alpha-1 -x 80 -y 24
    export SALA_WEB_TMUX_SOCKET="$TSOCK"   # for the direct calls below; the probe pane gets it from its wrapper
    # run inside a second private tmux client so exec tmux attach has a terminal: the script's own pane shows what it did
    B="$T/bin"; mkdir -p "$B"; printf '#!/bin/sh\nSALA_WEB_TMUX_SOCKET=%s exec %s "$@"\n' "$TSOCK" "$A" > "$B/run"; chmod +x "$B/run"
    tmux -L "$TSOCK" -f /dev/null new-session -d -s probe -x 100 -y 30 "$B/run alpha-1; sleep 30"
    waitfor "tmux -L $TSOCK list-clients -t alpha-1 2>/dev/null | grep -q ." 20 && ok "a valid existing session is attached" || bad "no client attached to alpha-1"
    tmux -L "$TSOCK" -f /dev/null kill-session -t probe 2>/dev/null
    out=$(printf '\n' | "$A" nosuch 2>&1); [[ $out == *'No tmux session named "nosuch"'* ]] && [[ $out == *alpha-1* ]] && ok "an unknown name: said so and listed the sessions" || bad "unknown: $out"
    out=$(printf '\n' | "$A" 'a;b' 2>&1); [[ $out == *"invalid session name"* ]] && ok "an invalid name never reaches tmux" || bad "invalid: $out"
    out=$(printf 'zzz\n' | "$A" 2>&1); [[ $out == *"No such session"* ]] && ok "a typed unknown name closes" || bad "typed: $out"
else
    ok "tmux not installed: the attach script is not exercised"
fi

[ "$fail" = 0 ] && echo "webinstall: pass" || echo "webinstall: FAIL"
exit $fail
