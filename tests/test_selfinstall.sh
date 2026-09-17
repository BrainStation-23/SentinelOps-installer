#!/usr/bin/env bash
# Exercise the staleness guard.
#
# `install` copies this tool into the installation root, so a `git pull` in the
# checkout leaves the command on PATH untouched. This guard is the only thing
# standing between that and an operator reading it as a missing feature. Its
# silence matters as much as its warning: a guard that cries stale on a healthy
# installation is one that gets ignored.
set -uo pipefail

ROOT="${1:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/config.sh"
source "${ROOT}/lib/selfinstall.sh"

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

T="$(mktemp -d)"

# A checkout and the installed copy taken from it, made with the same `cp -a`
# the installer uses.
mk_pair() {
    rm -rf "${T}/src" "${T}/root"
    mkdir -p "${T}/src/bin" "${T}/src/lib" "${T}/src/assets" "${T}/root"
    printf 'cli\n'   >"${T}/src/bin/sentinel-ops"
    printf 'lib\n'   >"${T}/src/lib/common.sh"
    printf 'asset\n' >"${T}/src/assets/template"
    cp -a "${T}/src/bin" "${T}/src/lib" "${T}/src/assets" "${T}/root/"
}

# What a pull does to the files it rewrites.
edit() { printf 'changed\n' >>"$1"; }

differs() {
    _installer_differs "${T}/src" "${T}/root" && printf 'differs' || printf 'same'
}

# --- Content comparison ----------------------------------------------------
mk_pair
check "untouched copy matches" "same" "$(differs)"

# Every tree the installer copies has to be compared, not just bin/.
mk_pair; edit "${T}/src/bin/sentinel-ops"
check "changed bin is detected" "differs" "$(differs)"

mk_pair; edit "${T}/src/lib/common.sh"
check "changed lib is detected" "differs" "$(differs)"

mk_pair; edit "${T}/src/assets/template"
check "changed asset is detected" "differs" "$(differs)"

# A command added upstream arrives as a new file, not a changed one - the case
# that started all this.
mk_pair; printf 'nuke\n' >"${T}/src/lib/nuke.sh"
check "added file is detected" "differs" "$(differs)"

# A new mtime on identical content is what a copy across filesystems and a
# no-op rebuild both look like. Neither is stale.
mk_pair; touch "${T}/src/lib/common.sh"
check "touch alone is not a change" "same" "$(differs)"

# --- The guard itself ------------------------------------------------------
# Only stderr is judged: the guard must never change an exit status, because
# every command in the tool runs after it.
warned() {
    local out
    out="$(warn_if_stale 2>&1 >/dev/null)"
    [[ -n "$out" ]] && printf 'warned' || printf 'silent'
}

setup_guard() {
    mk_pair
    config_set_paths "${T}/root"
    SO_ROOT="${T}/root"
}

setup_guard
state_set INSTALLED_FROM "${T}/src"
edit "${T}/src/lib/common.sh"
check "warns when the checkout moved on" "warned" "$(warned)"
warn_if_stale >/dev/null 2>&1
check "warning still returns success" "0" "$?"

# An installation nobody has pulled into is the common case and must be quiet.
setup_guard
state_set INSTALLED_FROM "${T}/src"
check "silent when the copy is current" "silent" "$(warned)"

# Installed before the guard existed, so no provenance was recorded.
setup_guard
check "silent without INSTALLED_FROM" "silent" "$(warned)"

# Installed from the curl bootstrap, whose temporary checkout is long gone.
setup_guard
state_set INSTALLED_FROM "${T}/src"
edit "${T}/src/lib/common.sh"
rm -rf "${T}/src"
check "silent when the checkout is gone" "silent" "$(warned)"

# Running a checkout directly is deliberate, whatever is installed elsewhere.
setup_guard
state_set INSTALLED_FROM "${T}/src"
edit "${T}/src/lib/common.sh"
SO_ROOT="${T}/src"
check "silent when run from a checkout" "silent" "$(warned)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
rm -rf "$T"
[[ $fail -eq 0 ]]
