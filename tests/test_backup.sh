#!/usr/bin/env bash
# Exercise the local backup logic in isolation from Docker: retention,
# checksums, metadata and listing. backup_create_full() itself (which shells
# out to `docker exec` for pg_dumpall) is Docker-invoking and not tested here
# - see the manual verification steps in docs/BACKUPS.md - but everything it
# delegates to for retention, integrity and listing is pure and asserted
# directly, the same split _domain_apply_settings/_domain_set already use.
set -uo pipefail

ROOT="${1:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/config.sh"
source "${ROOT}/lib/supabase.sh"
source "${ROOT}/lib/backup.sh"

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
config_set_paths "${T}/root"
config_make_dirs

_build_backups() {
    rm -rf "$BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    local stamp
    for stamp in 2026-01-01-000000 2026-01-02-000000 2026-01-03-000000 2026-01-04-000000 2026-01-05-000000; do
        mkdir -p "${BACKUP_DIR}/${stamp}"
        printf 'sql\n' >"${BACKUP_DIR}/${stamp}/database.sql"
    done
}
_remaining() {
    find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
        | LC_ALL=C sort | xargs -n1 basename | tr '\n' ' ' | sed 's/ $//'
}

# --- backup_prune_local: keep only the N most recent cycles -----------------
BACKUP_RETENTION_COUNT=3
_build_backups
backup_prune_local
check "prune keeps only the most recent N" \
    "2026-01-03-000000 2026-01-04-000000 2026-01-05-000000" "$(_remaining)"

BACKUP_RETENTION_COUNT=10
_build_backups
backup_prune_local
check "prune is a no-op under the limit" \
    "2026-01-01-000000 2026-01-02-000000 2026-01-03-000000 2026-01-04-000000 2026-01-05-000000" \
    "$(_remaining)"

# --- backup_latest -----------------------------------------------------------
_build_backups
check "backup_latest returns the newest" "${BACKUP_DIR}/2026-01-05-000000" "$(backup_latest)"

# --- checksums: write then verify round-trip, and catch corruption ----------
D="${T}/single"
mkdir -p "$D"
printf 'hello world\n' >"${D}/database.sql"
printf 'storage data\n' >"${D}/storage.tar.gz"
_backup_checksum_write "$D"
check "checksums.txt has one line per backed-up file" "2" "$(wc -l <"${D}/checksums.txt" | tr -d ' ')"

_backup_checksum_verify "$D" >/dev/null 2>&1
check "verify passes on an untouched backup" "0" "$?"

printf 'corrupted\n' >>"${D}/database.sql"
_backup_checksum_verify "$D" >/dev/null 2>&1
check "verify fails on a corrupted file" "1" "$?"

D2="${T}/missing-checksums"
mkdir -p "$D2"
_backup_checksum_verify "$D2" >/dev/null 2>&1
check "verify fails with no checksums.txt" "1" "$?"

# --- metadata -----------------------------------------------------------
D3="${T}/meta"
mkdir -p "$D3"
printf 'sql\n' >"${D3}/database.sql"
_backup_metadata_write "$D3" "unit-test"
check "metadata records the reason" "unit-test" "$(env_get "${D3}/metadata.txt" reason)"
check "metadata records scope=full"  "full"      "$(env_get "${D3}/metadata.txt" scope)"

# --- listing: newest first, carries each backup's reason --------------------
_build_backups
printf 'reason=oldest\n' >"${BACKUP_DIR}/2026-01-01-000000/metadata.txt"
printf 'reason=newest\n' >"${BACKUP_DIR}/2026-01-05-000000/metadata.txt"
entries="$(backup_list_entries)"
check "list is newest first"    "${BACKUP_DIR}/2026-01-05-000000" "$(printf '%s\n' "$entries" | head -n1 | cut -d'|' -f1)"
check "list carries the reason" "newest"                          "$(printf '%s\n' "$entries" | head -n1 | cut -d'|' -f3)"
check "list has all five entries" "5"                             "$(printf '%s\n' "$entries" | grep -c '.')"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
rm -rf "$T"
[[ $fail -eq 0 ]]
