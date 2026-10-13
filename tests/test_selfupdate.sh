#!/usr/bin/env bash
# Exercise self-update's validation, change detection and file swap.
#
# Downloading from GitHub is not exercised; `self-update from <path>` follows
# the same validate -> compare -> swap path, and that is what is tested here.
set -uo pipefail

ROOT="${1:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/config.sh"
source "${ROOT}/lib/selfinstall.sh"
source "${ROOT}/lib/commands/selfupdate.sh"

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

# A minimal installer tree that passes validation.
mk_tree() {
    local d="$1" v="${2:-1}"
    rm -rf "$d"
    mkdir -p "${d}/bin" "${d}/lib/commands" "${d}/assets/app"
    printf '#!/usr/bin/env bash\necho v%s\n' "$v" >"${d}/bin/sentinel-ops"
    for f in common config selfinstall; do printf '%s_v() { :; }\n' "$f" >"${d}/lib/${f}.sh"; done
    printf 'cmd_x() { :; }\n' >"${d}/lib/commands/x.sh"
    printf 'FROM node\n' >"${d}/assets/app/Dockerfile"
}

valid() { _selfupdate_validate "$1" >/dev/null 2>&1 && printf 'valid' || printf 'refused'; }

# --- Validation ----------------------------------------------------------------
mk_tree "${T}/new"
check "complete tree is accepted" "valid" "$(valid "${T}/new")"

mk_tree "${T}/new"; rm "${T}/new/lib/config.sh"
check "missing core library is refused" "refused" "$(valid "${T}/new")"

mk_tree "${T}/new"; rm -rf "${T}/new/assets"
check "missing assets/ is refused" "refused" "$(valid "${T}/new")"

mk_tree "${T}/new"; printf 'broken() {\n' >>"${T}/new/lib/commands/x.sh"
check "syntax error is refused" "refused" "$(valid "${T}/new")"

mk_tree "${T}/new"; printf 'x=1\r\n' >>"${T}/new/lib/common.sh"
check "CRLF is refused" "refused" "$(valid "${T}/new")"

# --- Change detection ----------------------------------------------------------
mk_tree "${T}/new"; mk_tree "${T}/cur"
check "identical trees: no changes" "" "$(_selfupdate_changes "${T}/new" "${T}/cur")"

touch "${T}/cur/lib/common.sh"
check "mtime alone is not a change" "" "$(_selfupdate_changes "${T}/new" "${T}/cur")"

mk_tree "${T}/new" 2
check "changed file is reported" "changed  bin/sentinel-ops" "$(_selfupdate_changes "${T}/new" "${T}/cur")"

mk_tree "${T}/new"; printf 'y\n' >"${T}/new/lib/commands/added.sh"
check "added file is reported" "added    lib/commands/added.sh" "$(_selfupdate_changes "${T}/new" "${T}/cur")"

mk_tree "${T}/new"; rm "${T}/new/assets/app/Dockerfile"
check "removed file is reported" "removed  assets/app/Dockerfile" "$(_selfupdate_changes "${T}/new" "${T}/cur")"

# --- Swap ------------------------------------------------------------------------
config_set_paths "${T}/root"
mk_tree "$INSTALL_DIR" 1
mkdir -p "${INSTALL_DIR}/config"; printf 'KEEP=1\n' >"${INSTALL_DIR}/config/installer.env"
printf 'stale\n' >"${INSTALL_DIR}/lib/commands/gone.sh"
mk_tree "${T}/new" 2

# A process already running the old CLI holds it open; the swap must leave
# that file intact rather than rewrite it underneath.
exec 8<"${INSTALL_DIR}/bin/sentinel-ops"
_selfupdate_swap "${T}/new"
check "swap succeeds" "0" "$?"
check "new CLI is in place" "echo v2" "$(tail -n1 "${INSTALL_DIR}/bin/sentinel-ops")"
check "new CLI is executable" "yes" "$([[ -x "${INSTALL_DIR}/bin/sentinel-ops" ]] && printf yes || printf no)"
check "running process still reads the old CLI" "echo v1" "$(tail -n1 <&8)"
exec 8<&-
check "files dropped upstream are gone" "no" "$([[ -e "${INSTALL_DIR}/lib/commands/gone.sh" ]] && printf yes || printf no)"
check "previous copy is kept" "echo v1" "$(tail -n1 "${INSTALL_DIR}/.installer-prev/bin/sentinel-ops")"
check "staging is cleaned up" "no" "$([[ -e "${INSTALL_DIR}/.installer-new" ]] && printf yes || printf no)"
check "config is untouched" "KEEP=1" "$(cat "${INSTALL_DIR}/config/installer.env")"
check "source tree is untouched" "echo v2" "$(tail -n1 "${T}/new/bin/sentinel-ops")"
check "result matches the source" "" "$(_selfupdate_changes "${T}/new" "$INSTALL_DIR")"

# A second update replaces the kept copy rather than nesting inside it.
mk_tree "${T}/new" 3
_selfupdate_swap "${T}/new"
check "previous copy rotates" "echo v2" "$(tail -n1 "${INSTALL_DIR}/.installer-prev/bin/sentinel-ops")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
rm -rf "$T"
[[ $fail -eq 0 ]]
