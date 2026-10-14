#!/usr/bin/env bash
# Exercise `sentinel-ops branch`: name validation, and that a switched branch
# survives the installer.env round trip every update and auto-update reads it
# from. The switch itself (ls-remote, fetch, cmd_update_app) needs a live
# installation and is not run.
set -uo pipefail

ROOT="${1:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/config.sh"
source "${ROOT}/lib/commands/branch.sh"

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
valid() { _branch_valid_name "$1" && printf yes || printf no; }

# --- branch names ------------------------------------------------------------
check "plain name"              "yes" "$(valid dev)"
check "name with a slash"       "yes" "$(valid release/2026.10)"
check "empty"                   "no"  "$(valid '')"
check "looks like an option"    "no"  "$(valid --upload-pack=x)"
check "contains a space"        "no"  "$(valid 'my branch')"
check "contains .."             "no"  "$(valid 'a..b')"
check "ends in .lock"           "no"  "$(valid 'dev.lock')"

# --- persistence ---------------------------------------------------------------
T="$(mktemp -d)"
config_set_paths "${T}/root"
APP_BRANCH="dev"
config_save
APP_BRANCH="main"
config_load
check "APP_BRANCH round-trips through installer.env" "dev" "$APP_BRANCH"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
rm -rf "$T"
[[ $fail -eq 0 ]]
