#!/usr/bin/env bash
# Exercise the two parts of `nuke` that decide what gets deleted.
#
# This command removes a database. The path guard is what stands between a
# mistyped --dir and `rm -rf /`, and the keep-list is what an operator relies
# on when they pass --keep-backups. Both are worth asserting rather than
# trusting to a careful reading.
set -uo pipefail

ROOT="${1:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/config.sh"
source "${ROOT}/lib/commands/nuke.sh"

pass=0; fail=0
check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        printf 'PASS  %s\n' "$desc"; pass=$((pass+1))
    else
        printf 'FAIL  %s\n        expected: [%s]\n        actual:   [%s]\n' "$desc" "$expected" "$actual"
        fail=$((fail+1))
    fi
}

# --- Path guard ------------------------------------------------------------
# die() exits, so each case runs in a subshell and is judged on its status.
_guard() {
    INSTALL_DIR="$1"
    ( _nuke_check_install_dir >/dev/null 2>&1 ) && printf 'allowed' || printf 'refused'
}

check "guard refuses empty"       "refused" "$(_guard '')"
check "guard refuses /"           "refused" "$(_guard '/')"
check "guard refuses /usr"        "refused" "$(_guard '/usr')"
check "guard refuses /var"        "refused" "$(_guard '/var')"
check "guard refuses /opt"        "refused" "$(_guard '/opt')"
check "guard refuses /home"       "refused" "$(_guard '/home')"
check "guard refuses /root"       "refused" "$(_guard '/root')"
check "guard refuses relative"    "refused" "$(_guard 'sentinel-ops')"
check "guard refuses ./relative"  "refused" "$(_guard './sentinel-ops')"
check "guard allows install root" "allowed" "$(_guard '/opt/sentinel-ops')"
check "guard allows custom root"  "allowed" "$(_guard '/srv/so-test')"

# --- Keep-list -------------------------------------------------------------
T="$(mktemp -d)"

# A tree shaped like a real installation, including the dot-directory that a
# `find`-based sweep is most likely to miss.
_build() {
    rm -rf "${T}/root"
    mkdir -p "${T}/root"/{config,supabase/volumes/db/data,app,backups/2026-01-01,.state/phases,logs,runtime}
    printf 'key\n' >"${T}/root/config/deploy_key"
    printf 'sql\n' >"${T}/root/backups/2026-01-01/database.sql"
    printf 'done\n' >"${T}/root/.state/phases/frontend"
}

_remaining() {
    ls -A "${T}/root" 2>/dev/null | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//'
}

config_set_paths "${T}/root"

_build
NUKE_KEEP_BACKUPS="false"; NUKE_KEEP_CONFIG="false"
_nuke_filesystem >/dev/null 2>&1
check "full nuke removes the root" "gone" "$([[ -d "${T}/root" ]] && printf 'present' || printf 'gone')"

_build
NUKE_KEEP_BACKUPS="true"; NUKE_KEEP_CONFIG="true"
_nuke_filesystem >/dev/null 2>&1
check "keep-all leaves both"        "backups config" "$(_remaining)"
check "keep-all keeps deploy key"   "key"            "$(cat "${T}/root/config/deploy_key" 2>/dev/null)"
check "keep-all keeps the dump"     "sql"            "$(cat "${T}/root/backups/2026-01-01/database.sql" 2>/dev/null)"

_build
NUKE_KEEP_BACKUPS="true"; NUKE_KEEP_CONFIG="false"
_nuke_filesystem >/dev/null 2>&1
check "keep-backups drops config"   "backups"        "$(_remaining)"

_build
NUKE_KEEP_BACKUPS="false"; NUKE_KEEP_CONFIG="true"
_nuke_filesystem >/dev/null 2>&1
check "keep-config drops backups"   "config"         "$(_remaining)"
# Phase markers must go, or a reinstall would skip the phases it needs to redo.
check "keep-config drops .state"    "gone" \
    "$([[ -d "${T}/root/.state" ]] && printf 'present' || printf 'gone')"

# A missing directory is a no-op, not an error: nuke is safe to run twice.
rm -rf "${T}/root"
NUKE_KEEP_BACKUPS="false"; NUKE_KEEP_CONFIG="false"
_nuke_filesystem >/dev/null 2>&1
check "second run is a no-op"       "0" "$?"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
rm -rf "$T"
[[ $fail -eq 0 ]]
