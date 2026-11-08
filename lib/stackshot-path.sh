# lib/stackshot-path.sh — where a stackshot program is inside stackshot's checkout (SALA_STACKSHOT_DIR). Sourced by lib/common.sh and
# by release.sh (which reads no config and sources no other lib file); defines functions only, never exits.
#
# stackshot moved its programs from the checkout's root into a package, and leaves a forwarder at each old root path for two weeks
# (until Sun Nov 22nd 2026). Every sala caller that names one of them asks this file, so a box whose checkout is older than the move
# keeps working and the old paths can be dropped in one place:
#
#   client          stackshot/fleet/client.py      (was client.py)
#   pages           stackshot/projects/pages.py    (was pages.py)
#   publish         stackshot/web/publish.py       (was publish.py)
#   open_item_text  stackshot/tools/open_item_text.py   (was tools/open_item_text.py)
#
#   stackshot_prog_r <var> <dir> <name>   <var> = <dir>/<the program's path>: the package path when that file exists, else the old
#                                         root path when only that one exists (an older checkout), else the package path (the one to
#                                         name in a message). Empty <dir> (no stackshot on this box): <var> empty, status 1; an
#                                         unknown <name>: <var> empty, status 2. No fork.
#   stackshot_prog <dir> <name>           the same on stdout, for `$(…)`.
#   stackshot_rel_r <var> <dir> <name>    <var> = only the path below <dir> (what a printed command repeats after its own `~/stackshot/`)
#
# A setting that names the file itself (SALA_STACKSHOT_CLIENT, STACKSHOT_CLIENT, SALA_AGENT_CHECK_SCRIPT, SALA_SPAWN_ASK_CMD,
# SALA_SIDE_*_CMD, a command in the config) is used as written, never probed: only the paths derived from the directory go through here.
stackshot_rel_r() {  # <var> <dir> <name>
    local _new _old
    printf -v "$1" %s ""
    [ -n "${2:-}" ] || return 1
    case "${3:-}" in
        client)         _new=stackshot/fleet/client.py;          _old=client.py ;;
        pages)          _new=stackshot/projects/pages.py;        _old=pages.py ;;
        publish)        _new=stackshot/web/publish.py;           _old=publish.py ;;
        open_item_text) _new=stackshot/tools/open_item_text.py;  _old=tools/open_item_text.py ;;
        *) return 2 ;;
    esac
    if [ -f "$2/$_new" ] || [ ! -f "$2/$_old" ]; then printf -v "$1" %s "$_new"; else printf -v "$1" %s "$_old"; fi
}
stackshot_prog_r() {  # <var> <dir> <name>
    local _rel _rc=0
    stackshot_rel_r _rel "${2:-}" "${3:-}" || _rc=$?
    if [ "$_rc" = 0 ]; then printf -v "$1" %s "${2%/}/$_rel"; else printf -v "$1" %s ""; fi
    return "$_rc"
}
stackshot_prog() {  # <dir> <name>
    local _p; stackshot_prog_r _p "${1:-}" "${2:-}" || return $?
    printf '%s\n' "$_p"
}
