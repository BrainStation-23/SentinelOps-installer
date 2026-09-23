#!/usr/bin/env bash
# Exercise lib/repair.sh's env_lint/env_repair_file: a pure text transform, so
# it is tested the same way as the Azure compose patch - against a fixture,
# without Docker or a live Supabase stack.
set -uo pipefail

ROOT="${1:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/repair.sh"

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

# --- a clean file: nothing to report, nothing to fix ------------------------
CLEAN="${T}/clean.env"
printf 'FOO=bar\nSITE_URL=https://example.com\n# a comment\n\nAPI_EXTERNAL_URL=https://example.com\n' >"$CLEAN"
BEFORE_CLEAN="$(cat "$CLEAN")"

check "clean file: no lint issues" "" "$(env_lint "$CLEAN")"
env_repair_file "$CLEAN"; rc="$?"
check "clean file: env_repair_file reports no change" "1" "$rc"
check "clean file: left byte-for-byte untouched" "$BEFORE_CLEAN" "$(cat "$CLEAN")"
check "clean file: no backup was created" "0" "$(ls "${T}"/clean.env.bak-* 2>/dev/null | wc -l)"

# --- a fixture mirroring every known-fixable problem ------------------------
DIRTY="${T}/dirty.env"
{
    printf 'FOO=bar\r\n'                       # CRLF
    printf 'BAZ=qux   \n'                      # trailing whitespace
    printf 'QUX = value\n'                     # spaces around "="
    printf 'QUUX= value2\n'                    # space after "="
    printf 'CORGE =value3\n'                   # space before "="
    printf '# a comment, left alone\n'
    printf '\n'
    printf 'DUP=first\n'
    printf 'DUP=second\n'                      # duplicate key, last should win
    printf 'SITE_URL=https://example.com/\n'
    printf 'API_EXTERNAL_URL=https://example.com/\n'
    printf 'SUPABASE_PUBLIC_URL=https://example.com/\n'
} >"$DIRTY"

LINT_OUT="$(env_lint "$DIRTY")"
check "lint: detects CRLF"                    "1" "$(printf '%s\n' "$LINT_OUT" | grep -c 'CRLF line endings')"
check "lint: detects trailing whitespace"     "1" "$(printf '%s\n' "$LINT_OUT" | grep -c 'trailing whitespace')"
check "lint: detects spaced assignment"       "1" "$(printf '%s\n' "$LINT_OUT" | grep -c 'whitespace around one or more')"
check "lint: detects duplicate key"           "1" "$(printf '%s\n' "$LINT_OUT" | grep -c 'duplicate key: DUP')"
check "lint: detects trailing slash (SITE_URL)" \
    "1" "$(printf '%s\n' "$LINT_OUT" | grep -c 'SITE_URL has a trailing slash')"
check "lint: detects trailing slash (API_EXTERNAL_URL)" \
    "1" "$(printf '%s\n' "$LINT_OUT" | grep -c 'API_EXTERNAL_URL has a trailing slash')"
check "lint: detects trailing slash (SUPABASE_PUBLIC_URL)" \
    "1" "$(printf '%s\n' "$LINT_OUT" | grep -c 'SUPABASE_PUBLIC_URL has a trailing slash')"

env_repair_file "$DIRTY"; rc="$?"
check "repair: reports a change was made" "0" "$rc"

check "repair: CRLF stripped"                    "1" "$(grep -c '^FOO=bar$' "$DIRTY")"
grep -qU $'\r' "$DIRTY" && cr_left=1 || cr_left=0
check "repair: no CRLF remains"                  "0" "$cr_left"
check "repair: trailing whitespace trimmed"      "1" "$(grep -c '^BAZ=qux$' "$DIRTY")"
check "repair: spaced assignment tightened (QUX)"   "1" "$(grep -c '^QUX=value$' "$DIRTY")"
check "repair: spaced assignment tightened (QUUX)"  "1" "$(grep -c '^QUUX=value2$' "$DIRTY")"
check "repair: spaced assignment tightened (CORGE)" "1" "$(grep -c '^CORGE=value3$' "$DIRTY")"
check "repair: comment left alone"               "1" "$(grep -c '^# a comment, left alone$' "$DIRTY")"
check "repair: duplicate key resolved to last occurrence" "1" "$(grep -c '^DUP=second$' "$DIRTY")"
check "repair: earlier duplicate removed"        "0" "$(grep -c '^DUP=first$' "$DIRTY")"
check "repair: trailing slash stripped (SITE_URL)" \
    "1" "$(grep -c '^SITE_URL=https://example.com$' "$DIRTY")"
check "repair: trailing slash stripped (API_EXTERNAL_URL)" \
    "1" "$(grep -c '^API_EXTERNAL_URL=https://example.com$' "$DIRTY")"
check "repair: trailing slash stripped (SUPABASE_PUBLIC_URL)" \
    "1" "$(grep -c '^SUPABASE_PUBLIC_URL=https://example.com$' "$DIRTY")"
check "repair: a backup was created" "1" "$(ls "${T}"/dirty.env.bak-* 2>/dev/null | wc -l)"
check "lint: fixed file is now clean" "" "$(env_lint "$DIRTY")"

# --- idempotency: a second run changes nothing further ----------------------
AFTER_FIRST="$(cat "$DIRTY")"
env_repair_file "$DIRTY"; rc="$?"
check "repair: second run reports no change" "1" "$rc"
check "repair: second run is byte-for-byte idempotent" "$AFTER_FIRST" "$(cat "$DIRTY")"

# --- a missing file is reported, not crashed on -----------------------------
MISSING="${T}/does-not-exist.env"
check "lint: missing file is reported" "missing: ${MISSING}" "$(env_lint "$MISSING")"
env_repair_file "$MISSING"; rc="$?"
check "repair: missing file returns non-zero" "1" "$rc"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
rm -rf "$T"
[[ $fail -eq 0 ]]
