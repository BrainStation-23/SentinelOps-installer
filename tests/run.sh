#!/usr/bin/env bash
# Run every check that does not need a live server.
#
#   ./tests/run.sh
#
# Covers: shell syntax, shellcheck (when installed), CRLF contamination, and
# the unit tests for the helpers the deployment logic depends on.
set -uo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail=0
hr() { printf '\n== %s ==\n' "$1"; }

SCRIPTS=(install.sh bin/sentinel-ops lib/*.sh lib/commands/*.sh tests/*.sh)

hr "Shell syntax"
for f in "${SCRIPTS[@]}"; do
    if bash -n "$f" 2>/tmp/so-syntax-err; then
        printf 'ok    %s\n' "$f"
    else
        printf 'FAIL  %s\n' "$f"; cat /tmp/so-syntax-err; fail=1
    fi
done
rm -f /tmp/so-syntax-err

hr "Line endings"
# A CRLF in any of these files breaks the shebang on Linux.
crlf=0
for f in "${SCRIPTS[@]}" assets/app/Dockerfile assets/app/dockerignore; do
    if grep -qU $'\r' "$f" 2>/dev/null; then
        printf 'FAIL  %s contains CRLF\n' "$f"; crlf=1; fail=1
    fi
done
(( crlf )) || printf 'ok    all files use LF\n'

hr "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
    # SC1091: sourced libraries are resolved at runtime, not statically.
    if shellcheck -e SC1091 -S warning "${SCRIPTS[@]}"; then
        printf 'ok    shellcheck clean\n'
    else
        printf 'FAIL  shellcheck reported issues\n'; fail=1
    fi
else
    printf 'skip  shellcheck not installed\n'
fi

hr "Unit tests"
for t in tests/test_*.sh; do
    printf '\n-- %s\n' "$t"
    bash "$t" || fail=1
done

hr "Result"
if (( fail )); then
    printf 'FAILED\n'; exit 1
fi
printf 'All checks passed\n'
