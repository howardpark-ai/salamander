# lib/webunits.sh — the web UI's systemd user units: installed from web/contrib/, and migrated from the name they had
# before (Nov 2026: the units, the command, the socket and the state directory are named sala-web). Sourced by install.sh
# and deploy.sh, never by bin/salamander. Needs bash; sets no option of its caller's.
#
#   web_units_dir                     where the user units live: $XDG_CONFIG_HOME/systemd/user (default ~/.config/...)
#   web_setting NAME                  NAME from the environment, else its line in sala's config file, ~ and $HOME expanded
#   web_units_install ROOT            the three units copied from ROOT/web/contrib with ROOT in place of %h/salamander
#                                     (a path under $HOME written as %h/...), SALA_WEB_SOCKET written as the ListenStream=
#   web_legacy_name                   the old name of the units, when they are installed here; else nothing (exit 1)
#   web_legacy_alias_name             the old name once the migration has run (its units are aliases of the new ones); else nothing
#   web_legacy_cmd_link ROOT          ROOT/web/.venv/bin/<old name> -> sala-web, when the old name is known and that path is free
#   web_migrate ROOT                  the migration below, on an install that has the old units; nothing otherwise
#   web_state_merge                   the state directories merged (step 4), on an install whose old units are already aliases and
#                                     whose old state directory is still there beside the new one; nothing otherwise
#
# THE MIGRATION (web_migrate). The old units are found by what they are, never by a name written here: a service X.service
# in the units directory (X not sala-web) whose ExecStart= runs <checkout>/web/.venv/bin/X and that Requires=X.socket is the
# web UI under its old name X; X.socket and X-ttyd.service are its socket and its terminal. Then, in this order:
#   1. the venv is synced (uv sync --frozen in web/) when it has no sala-web command yet, so the new unit can start;
#   2. the new units are installed (web_units_install);
#   3. the old units are stopped and disabled, and each old unit file is kept beside itself as <file>.migrated and replaced by
#      a symlink to its new unit (an alias: `systemctl --user restart X.service` restarts sala-web.service for one release,
#      which is what the previous deploy.sh does right after the deploy that brings this file); every *.conf in an old unit's
#      drop-in directory (X.service.d, X.socket.d, X-ttyd.service.d) is copied into the new unit's (sala-web.service.d,
#      sala-web.socket.d, sala-web-ttyd.service.d) unless a file of that name is already there (left as it is, and a line says
#      so). The old directories stay where they are: systemd reads drop-ins by the unit's own name, so an alias's old directory
#      no longer applies to the new unit, and nothing else reads it;
#   4. the old state directory ($XDG_STATE_HOME/X) is moved to the new one when the new one does not exist yet. When both
#      exist (sala-web ran, and wrote its caches, before the move), they are MERGED with sala-web.socket and sala-web.service
#      stopped: every entry of the old directory that the new one lacks is moved in (mv, no copy; one line each). Of the files
#      the user owns (prefs.json, read-state.json, mandates/, uploads/: everything the app keeps that is not a cache) the old
#      one wins over a new one of the same name, the new one kept beside it as <name>.before-merge-<epoch>, and the two
#      directories are merged entry by entry; a cache (board-items, quota-*, spend-*, api-spend, *-debug.log) stays the new
#      one. What is left in the old directory stays there and a line lists it (an emptied directory is removed). The units
#      stopped for the merge are started again by step 6 (by web_state_merge itself on an install already migrated);
#   5. when the old socket paths differ from the new ones, a drop-in sala-web.service.d/old-socket-path.conf names them
#      (SALA_WEB_COMPAT_SOCKET, SALA_WEB_COMPAT_TTYD_SOCKET) and recreates their parent directories at each start: the app
#      then links each old path to the socket it stands for, so a proxy still pointing at an old path keeps working;
#   6. daemon-reload, then each new unit enabled when its old one was enabled and started when its old one was running.
# A second run finds no old unit (its file is now an alias of the new one) and does nothing.
#
# THE OLD COMMAND (web_legacy_cmd_link). Tooling outside this repository may still run <checkout>/web/.venv/bin/X directly, and
# the package installs only sala-web there. The old name cannot be written in pyproject.toml (the repository carries no instance
# name), so the install and the deploy make the link instead: web/.venv/bin/X -> sala-web, once the old name is known (the old
# units are found, or are aliases of the new ones: web_legacy_alias_name) and that path does not exist. web_migrate does it, and
# so do install.sh --web and deploy.sh's web step on every run (a venv rebuilt by uv sync loses the link).
# Dropping the compatibility later: delete the drop-in, the alias symlinks and the link (web/README.md, *Renamed units*).

web_units_dir() { printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"; }

web_setting() {
    local n="$1" v="${!1:-}"
    if [ -z "$v" ]; then
        v=$( (grep -E "^(export )?$n=" "${SALA_CONFIG:-$HOME/.config/salamander/config}" 2>/dev/null || true) | tail -1 | cut -d= -f2- \
            | sed -e 's/[[:space:]]*#.*$//' -e "s/[\"']//g")
    fi
    case "$v" in "~/"*) v="$HOME/${v#"~/"}" ;; '$HOME/'*) v="$HOME/${v#'$HOME/'}" ;; '${HOME}/'*) v="$HOME/${v#'${HOME}/'}" ;; esac
    printf '%s' "$v"
}

# a path a unit line can carry: no space, no % (a specifier), no $ (an environment reference), no quote
_web_unit_safe() { case "$1" in *[!A-Za-z0-9._/+@-]*) return 1 ;; esac; }

web_units_install() {
    local root="$1" units wroot pat="%h/salamander/web" u tmp content sock
    _web_unit_safe "$root" || { echo "install.sh --web: the checkout's path ($root) has a character a unit's ExecStart cannot carry safely; move it to a plain path" >&2; return 1; }
    sock=$(web_setting SALA_WEB_SOCKET)
    if [ -n "$sock" ]; then
        case "$sock" in /*) ;; *) echo "install.sh --web: SALA_WEB_SOCKET ($sock) is not an absolute path" >&2; return 1 ;; esac
        _web_unit_safe "$sock" || { echo "install.sh --web: SALA_WEB_SOCKET ($sock) has a character a unit cannot carry safely" >&2; return 1; }
    fi
    # a checkout under $HOME is written as %h/<path>, so the units survive a changed home; elsewhere the absolute path
    case "$root" in "$HOME"/*) wroot="%h/${root#"$HOME"/}" ;; *) wroot="$root" ;; esac
    units=$(web_units_dir)
    mkdir -p "$units" || { echo "install.sh --web: cannot create $units" >&2; return 1; }
    for u in sala-web.socket sala-web.service sala-web-ttyd.service; do
        tmp="$units/.$u.$$"
        content=$(cat "$root/web/contrib/$u"; echo x) || { echo "install.sh --web: cannot read $root/web/contrib/$u" >&2; return 1; }
        content=${content%x}
        content=${content//"$pat"/$wroot/web}
        if [ -n "$sock" ] && [ "$u" = sala-web.socket ]; then
            content=$(printf '%s' "$content" | sed "s#^ListenStream=.*#ListenStream=$sock#"; echo x); content=${content%x}
        fi
        # a failed write (disk full, a folder that is not writable) removes the temporary file and stops, never reports success
        if ! { printf "%s" "$content" > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$units/$u"; }; then
            rm -f "$tmp"; echo "install.sh --web: cannot write $units/$u" >&2; return 1
        fi
    done
}

# is FILE (named X.service-ish) the web UI under the old name X: ExecStart runs <checkout>/web/.venv/bin/X and it Requires=X.socket
_web_old_service() {
    local f="$1" x="$2"
    case "$x" in sala-web|sala-web-ttyd|*-ttyd) return 1 ;; esac
    grep -Eq "^ExecStart=[^[:space:]]*/web/\.venv/bin/$x([[:space:]]|\$)" "$f" && grep -Eq "^Requires=(.*[[:space:]])?$x\.socket([[:space:]]|\$)" "$f"
}

web_legacy_name() {
    local units f x
    units=$(web_units_dir)
    [ -d "$units" ] || return 1
    for f in "$units"/*.service; do
        [ -f "$f" ] && [ ! -L "$f" ] || continue
        x=$(basename "$f" .service)
        _web_old_service "$f" "$x" && { printf '%s\n' "$x"; return 0; }
    done
    return 1
}

# the old name after the migration: X.service is an alias of sala-web.service and X.service.migrated is the old unit
web_legacy_alias_name() {
    local units f x
    units=$(web_units_dir)
    [ -d "$units" ] || return 1
    for f in "$units"/*.service; do
        [ -L "$f" ] && [ "$(readlink "$f")" = sala-web.service ] && [ -f "$f.migrated" ] || continue
        x=$(basename "$f" .service)
        _web_old_service "$f.migrated" "$x" && { printf '%s\n' "$x"; return 0; }
    done
    return 1
}

web_legacy_cmd_link() {
    local root="$1" x bin="$1/web/.venv/bin"
    x=$(web_legacy_name) || x=$(web_legacy_alias_name) || return 0
    [ -x "$bin/sala-web" ] || return 0
    if [ -e "$bin/$x" ] || [ -L "$bin/$x" ]; then return 0; fi
    ln -s sala-web "$bin/$x" || { echo "web: cannot link $bin/$x to sala-web" >&2; return 1; }
    echo "web: $bin/$x -> sala-web (the old command, kept for one release)"
}

# every *.conf of an old unit's drop-in directory copied into the new unit's, unless a file of that name is already there
_web_carry_dropins() {
    local src="$1" dst="$2" f b
    [ -d "$src" ] || return 0
    for f in "$src"/*.conf; do
        [ -f "$f" ] || continue
        b=$(basename "$f")
        if [ -e "$dst/$b" ] || [ -L "$dst/$b" ]; then
            echo "web: note: $dst/$b exists; $f is not copied over it"; continue
        fi
        { mkdir -p "$dst" && cp -p "$f" "$dst/$b"; } || { echo "web: cannot copy $f to $dst/$b" >&2; return 1; }
        echo "web: drop-in carried over: $f → $dst/$b"
    done
}

# The entries of the state directory that are the user's own, not a cache: web/src/sala_web/config.py (uploads_dir, mandates_dir),
# app.py (prefs.json) and unread.py (read-state.json). Every other file there is a cache the app rebuilds (board-items.json,
# quota-*.json, spend-*.json, api-spend.json, *-debug.log).
_web_user_owned() { case "$1" in prefs.json|read-state.json|mandates|uploads) return 0 ;; esac; return 1; }

# Before the first entry is moved, and only then (a run with nothing to move touches no unit): the web socket and service stopped
# (the socket first, a request would start the service again), those that were active remembered in _WEB_STOPPED.
_web_quiesce() {
    local u
    [ "${_WEB_QUIESCED:-0}" = 0 ] || return 0
    _WEB_QUIESCED=1
    echo "web: both $_WEB_OLDSTATE and $_WEB_NEWSTATE exist (sala-web ran before the move); merging them, with sala-web stopped"
    for u in sala-web.socket sala-web.service; do
        if systemctl --user is-active --quiet "$u" 2>/dev/null; then _WEB_STOPPED+=("$u"); fi
    done
    for u in sala-web.socket sala-web.service; do systemctl --user stop "$u" 2>/dev/null || true; done
}

# _web_merge_dir OLD NEW OWNED STAMP: every entry of OLD that NEW lacks is moved into it. On a name both have, a user's entry (OWNED=1,
# or the top-level name is in the list above) goes old over new, the new one kept aside; two directories of the user's are merged by
# the same rule; a cache is left in OLD. One line per entry moved.
_web_merge_dir() {
    local o="$1" n="$2" owned="$3" stamp="$4" e name own aside
    while IFS= read -r -d '' e; do
        name=${e##*/}; own=$owned
        [ -n "$own" ] || { if _web_user_owned "$name"; then own=1; else own=0; fi; }
        if [ ! -e "$n/$name" ] && [ ! -L "$n/$name" ]; then
            _web_quiesce
            mv -- "$e" "$n/$name" || { echo "web: cannot move $e to $n/$name" >&2; return 1; }
            echo "web: state: moved $e → $n/$name"
        elif [ "$own" = 1 ] && [ -d "$e" ] && [ ! -L "$e" ] && [ -d "$n/$name" ] && [ ! -L "$n/$name" ]; then
            _web_merge_dir "$e" "$n/$name" 1 "$stamp" || return 1
            rmdir -- "$e" 2>/dev/null || true
        elif [ "$own" = 1 ]; then
            aside="$n/$name.before-merge-$stamp"; _web_quiesce
            { mv -- "$n/$name" "$aside" && mv -- "$e" "$n/$name"; } || { echo "web: cannot replace $n/$name by $e" >&2; return 1; }
            echo "web: state: moved $e → $n/$name (the new one is kept as $aside)"
        fi
    done < <(find "$o" -mindepth 1 -maxdepth 1 -print0 | sort -z)
}

# _web_state_merge OLD: step 4 for the old name OLD. Sets _WEB_STOPPED to the new units it stopped; the caller starts them again.
_web_state_merge() {
    local old="$1" st_home oldstate newstate left
    _WEB_STOPPED=()
    st_home="${XDG_STATE_HOME:-$HOME/.local/state}"; oldstate="$st_home/$old"
    newstate=$(web_setting SALA_WEB_STATE_DIR); newstate="${newstate:-$st_home/sala-web}"
    [ -d "$oldstate" ] && [ ! -L "$oldstate" ] && [ "$oldstate" != "$newstate" ] || return 0
    if [ ! -e "$newstate" ]; then
        mkdir -p "$(dirname "$newstate")" && mv "$oldstate" "$newstate" \
            && echo "web: state directory moved: $oldstate → $newstate" \
            || { echo "web: cannot move $oldstate to $newstate" >&2; return 1; }
        return 0
    fi
    [ -d "$newstate" ] || { echo "web: $newstate exists and is not a directory; $oldstate is left as it is" >&2; return 1; }
    _WEB_QUIESCED=0; _WEB_OLDSTATE="$oldstate"; _WEB_NEWSTATE="$newstate"
    _web_merge_dir "$oldstate" "$newstate" "" "$(date +%s)" || return 1
    left=$(find "$oldstate" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort | paste -sd' ')
    if [ -z "$left" ]; then
        rmdir "$oldstate" && echo "web: state: $oldstate is empty and removed"
    elif [ "$_WEB_QUIESCED" = 1 ]; then
        echo "web: state: left in $oldstate (caches; sala-web uses the ones in $newstate): $left"
    fi
}

# the merge on an install whose units were migrated before the merge existed: the old state directory still beside the new one
web_state_merge() {
    local old rc=0
    old=$(web_legacy_alias_name) || return 0
    _web_state_merge "$old" || rc=$?
    if [ ${#_WEB_STOPPED[@]} != 0 ]; then
        systemctl --user start "${_WEB_STOPPED[@]}" || { echo "web: starting ${_WEB_STOPPED[*]} failed" >&2; rc=1; }
    fi
    return $rc
}

web_migrate() {
    local root="$1" old units oldsock oldttyd newsock newttyd pair o n en=() start=() dirs=() d
    old=$(web_legacy_name) || return 0
    units=$(web_units_dir)
    echo "web: the web UI's units are installed here under their old name ($old.*); migrating them to sala-web"
    # 1. the venv, so the new unit has its command
    if [ ! -x "$root/web/.venv/bin/sala-web" ]; then
        if command -v uv >/dev/null 2>&1; then
            (cd "$root/web" && uv sync --frozen 2>&1 | sed 's/^/  web: /'; exit "${PIPESTATUS[0]}") \
                || { echo "web: uv sync --frozen failed in $root/web; the old units are left as they were" >&2; return 1; }
        else
            echo "web: uv is not on PATH, so the venv has no sala-web command yet; the old units are left as they were" >&2; return 1
        fi
    fi
    web_legacy_cmd_link "$root" || return 1   # the old command, beside the new one
    # the old socket paths, from the old units themselves (%t kept: the drop-in hands it to systemd, which expands it)
    oldsock=$(sed -n 's/^ListenStream=//p' "$units/$old.socket" 2>/dev/null | tail -1)
    oldttyd=$(grep -o -- '--interface [^[:space:]]*' "$units/$old-ttyd.service" 2>/dev/null | tail -1 | cut -d' ' -f2)
    # 2. the new units
    web_units_install "$root" || return 1
    newsock=$(sed -n 's/^ListenStream=//p' "$units/sala-web.socket" | tail -1)
    newttyd=$(grep -o -- '--interface [^[:space:]]*' "$units/sala-web-ttyd.service" | tail -1 | cut -d' ' -f2)
    # 3. the old units: stopped, disabled, kept as <file>.migrated, replaced by an alias of the new unit
    for pair in "$old.service:sala-web.service" "$old-ttyd.service:sala-web-ttyd.service" "$old.socket:sala-web.socket"; do
        o=${pair%%:*}; n=${pair#*:}
        [ -f "$units/$o" ] && [ ! -L "$units/$o" ] || continue
        systemctl --user is-enabled --quiet "$o" 2>/dev/null && en+=("$n")
        systemctl --user is-active --quiet "$o" 2>/dev/null && start+=("$n")
        systemctl --user stop "$o" 2>/dev/null || true
        systemctl --user disable --quiet "$o" 2>/dev/null || true
        mv -f "$units/$o" "$units/$o.migrated" && ln -sfn "$n" "$units/$o" \
            || { echo "web: cannot replace $units/$o by an alias of $n" >&2; return 1; }
        _web_carry_dropins "$units/$o.d" "$units/$n.d" || return 1
        echo "web: $o stopped and disabled; its file is $o.migrated, and $o is now an alias of $n"
    done
    # 4. the state directory: moved, or merged with the new units stopped (the ones stopped are started again by step 6)
    _web_state_merge "$old" || return 1
    [ ${#_WEB_STOPPED[@]} = 0 ] || start+=("${_WEB_STOPPED[@]}")
    # 5. the old socket paths, kept working for one release
    local dropin="$units/sala-web.service.d/old-socket-path.conf" body=""
    if [ -n "$oldsock" ] && [ "$oldsock" != "$newsock" ]; then body+="Environment=SALA_WEB_COMPAT_SOCKET=$oldsock"$'\n'; dirs+=("$(dirname "$oldsock")"); fi
    if [ -n "$oldttyd" ] && [ "$oldttyd" != "$newttyd" ]; then body+="Environment=SALA_WEB_COMPAT_TTYD_SOCKET=$oldttyd"$'\n'; dirs+=("$(dirname "$oldttyd")"); fi
    if [ -n "$body" ]; then
        for d in "${dirs[@]}"; do body+="ExecStartPre=-/bin/mkdir -p -m 0700 $d"$'\n'; done
        mkdir -p "$(dirname "$dropin")" && printf '%s\n%s%s' \
            "# Written by the migration from the units' old name (lib/webunits.sh). Delete this file to drop the old socket paths." \
            "[Service]"$'\n' "$body" > "$dropin" \
            || { echo "web: cannot write $dropin" >&2; return 1; }
        echo "web: the old socket path(s) keep working through sala-web ($dropin): $(printf '%s' "$body" | sed -n 's/^Environment=[A-Z_]*=//p' | paste -sd' ')"
    fi
    # 6. the new units, as the old ones were
    systemctl --user daemon-reload || { echo "web: systemctl --user daemon-reload failed" >&2; return 1; }
    [ ${#en[@]} = 0 ] || systemctl --user enable --quiet "${en[@]}" || { echo "web: enabling ${en[*]} failed" >&2; return 1; }
    [ ${#start[@]} = 0 ] || systemctl --user start "${start[@]}" || { echo "web: starting ${start[*]} failed" >&2; return 1; }
    echo "web: migrated to sala-web (enabled: ${en[*]:-none}; started: ${start[*]:-none})"
}
