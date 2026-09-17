#!/usr/bin/env bash
#
# Sentinel Ops bootstrap installer.
#
# From a checkout:
#   sudo ./install.sh                 guided installation
#   sudo ./install.sh --yes           non-interactive, accept every default
#
# Straight from the internet (downloads the installer, then runs it):
#   curl -fsSL https://raw.githubusercontent.com/tanjil-al-mahmud/SentinelOPS-Installer-and-Deployment/main/install.sh | sudo bash
#
# This is a thin wrapper. It hands over to bin/sentinel-ops, which is also what
# gets installed onto the server, so there is only ever one code path.
#
set -euo pipefail

REPO_URL="https://github.com/tanjil-al-mahmud/SentinelOPS-Installer-and-Deployment"
REPO_BRANCH="${SENTINEL_OPS_INSTALLER_BRANCH:-main}"

# When piped from curl there is no script on disk, so BASH_SOURCE is unusable.
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    SCRIPT_DIR=""
fi
CLI="${SCRIPT_DIR:-}/bin/sentinel-ops"

# ---------------------------------------------------------------------------
# Bootstrap: fetch the installer when it is not already on disk
# ---------------------------------------------------------------------------
bootstrap_download() {
    local tmp url

    printf '[INFO]  Downloading the Sentinel Ops installer (%s)...\n' "$REPO_BRANCH" >&2

    if ! command -v tar >/dev/null 2>&1; then
        printf '[ERROR] tar is required to bootstrap the installer.\n' >&2
        exit 1
    fi

    tmp="$(mktemp -d)"
    url="${REPO_URL}/archive/refs/heads/${REPO_BRANCH}.tar.gz"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" | tar -xz -C "$tmp" --strip-components=1
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- "$url" | tar -xz -C "$tmp" --strip-components=1
    else
        printf '[ERROR] Neither curl nor wget is available.\n' >&2
        printf '        Install one, or clone the repository manually:\n' >&2
        printf '          git clone %s.git\n' "$REPO_URL" >&2
        exit 1
    fi

    SCRIPT_DIR="$tmp"
    CLI="${tmp}/bin/sentinel-ops"

    if [[ ! -f "$CLI" ]]; then
        printf '[ERROR] Download succeeded but %s is missing.\n' "$CLI" >&2
        exit 1
    fi
    printf '[OK]    Installer downloaded to %s\n' "$tmp" >&2
}

if [[ ! -f "$CLI" ]]; then
    bootstrap_download
fi

# A CRLF line ending here is the most common way this fails when the repository
# is cloned on Windows, and the error the shell gives is unhelpful.
if grep -q $'\r' "$CLI" 2>/dev/null; then
    printf '[ERROR] %s has Windows line endings (CRLF).\n' "$CLI" >&2
    printf 'Fix with:  sed -i "s/\\r$//" %s/bin/* %s/lib/*.sh %s/lib/commands/*.sh\n' \
        "$SCRIPT_DIR" "$SCRIPT_DIR" "$SCRIPT_DIR" >&2
    exit 1
fi

chmod +x "$CLI" 2>/dev/null || true

# When this script arrived through a pipe, stdin is the script itself rather
# than the terminal. Reattach the controlling terminal so the installer can
# still ask its questions - without this it would silently accept every default
# (localhost endpoints), which is fine for a local deployment but not for one
# that needs to be reachable under a real domain.
if [[ ! -t 0 && -e /dev/tty ]] && (: >/dev/tty) 2>/dev/null; then
    exec 0</dev/tty
fi

# No explicit command means install. Anything else is passed through, so
# ./install.sh status works too.
if (( $# == 0 )); then
    exec "$CLI" install
fi

case "$1" in
    -*) exec "$CLI" install "$@" ;;
    *)  exec "$CLI" "$@" ;;
esac
