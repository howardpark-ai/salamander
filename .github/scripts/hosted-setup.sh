#!/usr/bin/env bash
# hosted-setup.sh — what a bare GitHub-hosted Ubuntu runner lacks, installed for a job that needs it. A NO-OP anywhere else: on a
# developer's machine it prints one line and exits 0, so a job can call it unconditionally. The runner sets RUNNER_ENVIRONMENT=github-hosted on its own images only.
#
# Usage: hosted-setup.sh <tool>...
#   tmux    tmux (apt). The suites are written against 3.6 (Ubuntu 26.04's 3.6a); another version is a warning, not a failure.
#   lsof    lsof (apt): the process helpers of tests/smoke.sh and others.
#   ttyd    ttyd 1.7.7, the release's static binary, its sha256 pinned here (web/tests/ttyd_harness.py skips without it, and a
#           skipped browser test would read as a pass).
#   chrome  a headless Chromium for the web app's page tests: the image's Google Chrome is checked, never installed (conftest.py
#           skips a test without one, which on a hosted runner would hide a gone browser).
# Other tools a job needs are on the image already (git, gh, bash, gcc as `cc`, python3, jq, node, util-linux's flock, setsid, script);
# Python 3.14 and uv come from actions/setup-python and astral-sh/setup-uv (.github/actions/hosted-tools). Versions are pinned here or
# there, never "whatever apt has", except tmux and lsof, which are the distribution's.
set -euo pipefail

if [ "${RUNNER_ENVIRONMENT:-}" != github-hosted ]; then
    echo "hosted-setup: not a GitHub-hosted runner (RUNNER_ENVIRONMENT=${RUNNER_ENVIRONMENT:-<unset>}): nothing to install"
    exit 0
fi

TTYD_VERSION=1.7.7
# the release's own SHA256SUMS, for the two architectures GitHub's Linux runners come in
TTYD_SHA256_x86_64=8a217c968aba172e0dbf3f34447218dc015bc4d5e59bf51db2f2cd12b7be4f55
TTYD_SHA256_aarch64=b38acadd89d1d396a0f5649aa52c539edbad07f4bc7348b27b4f4b7219dd4165
TMUX_WANT=3.6

note() { echo "hosted-setup: $*"; }
warn() { echo "::warning title=hosted-setup::$*"; }
die() { echo "::error title=hosted-setup::$*"; exit 1; }

apt_install() {   # <package>... — only those whose command is not there yet; one apt update per run
    local p need=()
    for p in "$@"; do command -v "$p" >/dev/null 2>&1 || need+=("$p"); done
    [ ${#need[@]} -eq 0 ] && return 0
    note "apt install ${need[*]}"
    sudo apt-get update -qq
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${need[@]}"
}

install_ttyd() {
    if command -v ttyd >/dev/null 2>&1 && [ "$(ttyd --version 2>&1 | awk '{print $NF}')" = "$TTYD_VERSION" ]; then
        note "ttyd $TTYD_VERSION is there"; return 0
    fi
    local arch want var d
    arch=$(uname -m); var="TTYD_SHA256_$arch"; want=${!var:-}
    [ -n "$want" ] || die "no pinned ttyd $TTYD_VERSION checksum for $arch"
    d=$(mktemp -d "${RUNNER_TEMP:-/tmp}/hosted-ttyd.XXXXXX")   # its own empty folder; removed below on every exit of this function
    trap 'rm -rf "$d"' RETURN
    note "ttyd $TTYD_VERSION ($arch)"
    curl -fsSL --retry 3 -o "$d/ttyd" "https://github.com/tsl0922/ttyd/releases/download/$TTYD_VERSION/ttyd.$arch"
    echo "$want  $d/ttyd" | sha256sum -c --quiet - || die "ttyd $TTYD_VERSION: the download does not match its pinned sha256"
    sudo install -m 0755 "$d/ttyd" /usr/local/bin/ttyd
}

check_chrome() {
    local n
    for n in google-chrome google-chrome-stable chromium chromium-browser; do
        if command -v "$n" >/dev/null 2>&1; then note "browser: $n $("$n" --version 2>/dev/null | head -1)"; return 0; fi
    done
    die "no headless-capable Chrome or Chromium on this runner image: the web app's page tests would skip, and a skip reads as a pass"
}

[ $# -gt 0 ] || { echo "usage: hosted-setup.sh <tmux|lsof|ttyd|chrome>..." >&2; exit 2; }
for t in "$@"; do
    case "$t" in
        tmux)   apt_install tmux ;;
        lsof)   apt_install lsof ;;
        ttyd)   install_ttyd ;;
        chrome) check_chrome ;;
        *) echo "hosted-setup: unknown tool '$t' (tmux lsof ttyd chrome)" >&2; exit 2 ;;
    esac
done

for t in "$@"; do
    case "$t" in
        tmux)
            v=$(tmux -V | awk '{print $2}'); note "tmux $v"
            case "$v" in "$TMUX_WANT"*) ;; *) warn "tmux $v: the suites are written against $TMUX_WANT (Ubuntu 26.04's); use runner ubuntu-26.04, which ubuntu-latest becomes by Nov 19th 2026" ;; esac ;;
        lsof) note "lsof $(command -v lsof)" ;;
        ttyd) note "$(ttyd --version 2>&1 | head -1)" ;;
    esac
done
