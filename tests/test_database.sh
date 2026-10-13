#!/usr/bin/env bash
# Exercise lib/database.sh's session_replication_role grant against a fake
# `docker exec psql`, without Docker or a live Supabase stack. The fake keeps
# one bit of state - whether the grant exists - and records who ran what.
set -uo pipefail

ROOT="${1:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/database.sh"

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
export SUPABASE_DIR="$T"
printf 'POSTGRES_PASSWORD=secret\nPOSTGRES_DB=postgres\n' >"${T}/.env"
CALLS="${T}/calls"

_db_container() { printf 'cid'; }

# Fake state, reset per scenario. The grant lives in a file because db_psql
# runs at the end of a pipeline, in a subshell.
FAKE_VERSION=150008
FAKE_GRANTED="${T}/granted"
FAKE_GRANT_FAILS="false"

# docker exec -i -e PGPASSWORD=... cid psql -U <user> -d <db> ... ; SQL on stdin
docker() {
    local user="" a
    local args=("$@")
    for ((a = 0; a < ${#args[@]}; a++)); do
        [[ "${args[a]}" == "-U" ]] && user="${args[a+1]}"
    done
    local sql
    sql="$(cat)"
    printf '%s|%s\n' "$user" "$sql" >>"$CALLS"
    case "$sql" in
        "SHOW server_version_num;") printf '%s\n' "$FAKE_VERSION" ;;
        *has_parameter_privilege*)  [[ -e "$FAKE_GRANTED" ]] && printf 't\n' || printf 'f\n' ;;
        GRANT*)
            [[ "$user" == "supabase_admin" && "$FAKE_GRANT_FAILS" != "true" ]] || return 1
            : >"$FAKE_GRANTED"
            ;;
    esac
    return 0
}

_reset() {
    : >"$CALLS"
    rm -f "$FAKE_GRANTED"
    FAKE_VERSION=150008; FAKE_GRANT_FAILS="false"
}

grant_calls() { grep -c '|GRANT' "$CALLS"; }

# --- missing grant: granted once, as the superuser, to the migration role ---
_reset
check "status before grant" "false" "$(db_replication_role_status)"
db_ensure_replication_role_grant >/dev/null 2>&1; rc="$?"
check "missing grant: succeeds" "0" "$rc"
check "missing grant: one GRANT issued" "1" "$(grant_calls)"
check "missing grant: GRANT runs as supabase_admin" "supabase_admin" \
    "$(grep '|GRANT' "$CALLS" | cut -d'|' -f1)"
check "missing grant: grantee is the migration role" \
    'GRANT SET ON PARAMETER session_replication_role TO "postgres";' \
    "$(grep '|GRANT' "$CALLS" | cut -d'|' -f2-)"
check "missing grant: checks run as the migration role" "0" \
    "$(grep -v '|GRANT' "$CALLS" | grep -vc '^postgres|')"
check "status after grant" "true" "$(db_replication_role_status)"

# --- already granted: nothing issued (idempotent) ---------------------------
: >"$CALLS"
db_ensure_replication_role_grant >/dev/null 2>&1; rc="$?"
check "already granted: succeeds" "0" "$rc"
check "already granted: no GRANT issued" "0" "$(grant_calls)"

# --- a custom POSTGRES_USER is the grantee, and is quoted ------------------
_reset
printf 'POSTGRES_PASSWORD=secret\nPOSTGRES_USER=app"user\n' >"${T}/.env"
db_ensure_replication_role_grant >/dev/null 2>&1
check "custom user: identifier quoted" \
    'GRANT SET ON PARAMETER session_replication_role TO "app""user";' \
    "$(grep '|GRANT' "$CALLS" | cut -d'|' -f2-)"
printf 'POSTGRES_PASSWORD=secret\nPOSTGRES_DB=postgres\n' >"${T}/.env"

# --- the GRANT fails: reported, not fatal-silent ---------------------------
_reset
FAKE_GRANT_FAILS="true"
out="$(db_ensure_replication_role_grant 2>&1)"; rc="$?"
check "grant fails: returns non-zero" "1" "$rc"
check "grant fails: warns that restore will fail" "1" \
    "$(printf '%s\n' "$out" | grep -c 'backup from inside the application will fail')"

# --- PostgreSQL 14: no per-parameter grants, nothing attempted --------------
_reset
FAKE_VERSION=140011
check "pg14: status unsupported" "unsupported" "$(db_replication_role_status)"
db_ensure_replication_role_grant >/dev/null 2>&1; rc="$?"
check "pg14: returns non-zero" "1" "$rc"
check "pg14: no GRANT attempted" "0" "$(grant_calls)"

# --- unreadable version: cannot check, nothing attempted --------------------
_reset
FAKE_VERSION="garbage"
db_ensure_replication_role_grant >/dev/null 2>&1; rc="$?"
check "unreadable version: returns non-zero" "1" "$rc"
check "unreadable version: no GRANT attempted" "0" "$(grant_calls)"

rm -rf "$T"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
