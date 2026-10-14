#!/usr/bin/env bash
# Every key config_load reads must be written back by config_save. A key that
# is only loaded is silently reset by the next command that saves the config,
# which is how `auto-update enable` once installed its timer but left status
# reporting "Disabled".
set -uo pipefail

ROOT="${1:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/config.sh"

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

# The key list, read from config_load itself so a new key is covered as soon
# as it is added there.
keys=()
while IFS= read -r k; do keys+=("$k"); done < <(
    declare -f config_load | sed -n '/for key in/,/; do/p' \
        | tr -s ' \\;\n' '\n' | grep -E '^[A-Z][A-Z0-9_]+$'
)
check "found the keys config_load reads" "yes" "$( (( ${#keys[@]} > 30 )) && printf yes || printf no)"

T="$(mktemp -d)"
config_set_paths "${T}/root"
for k in "${keys[@]}"; do printf -v "$k" '%s' "saved-${k}"; done
config_save
for k in "${keys[@]}"; do printf -v "$k" '%s' ""; done
config_load
for k in "${keys[@]}"; do
    check "${k} round-trips" "saved-${k}" "${!k}"
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
rm -rf "$T"
[[ $fail -eq 0 ]]
