#!/usr/bin/env bash
# lib/backup.sh - full-stack backups: Postgres, Storage, edge functions and
# enough config to rebuild the install, plus local retention and the shared
# restore implementation.
#
# Each backup is a single directory per cycle (see backup_create_full()) so
# that restic (lib/restic.sh) can back up exactly that directory for the
# offsite/secondary copies, and a restic-sourced restore reproduces the
# identical shape a local restore already reads - one restore implementation
# regardless of source. See docs/BACKUPS.md.
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# Local backup creation
# ---------------------------------------------------------------------------

# Files a full-stack backup directory can contain, in the order a restore
# applies them (database always; the rest only for scope=full).
BACKUP_ARCHIVE_FILES=(storage.tar.gz functions.tar.gz config.tar.gz)

# Dump the database, archive Storage/functions/secrets, checksum and record
# what was running at the time. Prints the backup directory on stdout.
backup_create_full() {
    local label="${1:-manual}"
    local cid stamp dir

    if ! cid="$(_db_container)"; then
        log_error "Cannot back up: the database is not running."
        return 1
    fi

    stamp="$(timestamp)"
    dir="${BACKUP_DIR}/${stamp}"
    mkdir -p "$dir"

    log_info "Backing up the database to ${dir}..." >&2
    # pg_dumpall captures roles and every database, which is what a restore of
    # a Supabase stack actually needs.
    if ! docker exec -e PGPASSWORD="$(_db_pass)" "$cid" \
            pg_dumpall -U "$(_db_user)" --clean --if-exists >"${dir}/database.sql" 2>>"${SO_LOG_FILE:-/dev/null}"; then
        log_error "Database dump failed." >&2
        rm -rf "$dir"
        return 1
    fi

    log_info "Archiving Storage and edge functions..." >&2
    if [[ -d "${SUPABASE_DIR}/volumes/storage" ]]; then
        tar -czf "${dir}/storage.tar.gz" -C "${SUPABASE_DIR}/volumes" storage 2>>"${SO_LOG_FILE:-/dev/null}" \
            || log_warn "Could not archive the Storage volume; continuing without it." >&2
    fi
    if [[ -d "${SUPABASE_DIR}/volumes/functions" ]]; then
        tar -czf "${dir}/functions.tar.gz" -C "${SUPABASE_DIR}/volumes" functions 2>>"${SO_LOG_FILE:-/dev/null}" \
            || log_warn "Could not archive the functions volume; continuing without it." >&2
    fi

    # config.tar.gz holds supabase/.env (JWT_SECRET, POSTGRES_PASSWORD, API
    # keys), installer.env and the deploy key - everything a fresh box needs
    # besides this directory itself to reconstitute the install. Locked down
    # immediately since tar has no atomic "create with these permissions".
    if [[ -f "${SUPABASE_DIR}/.env" ]]; then
        local config_args=(-C "$SUPABASE_DIR" .env)
        [[ -f "${CONFIG_DIR}/installer.env" ]] && config_args+=(-C "$CONFIG_DIR" installer.env)
        [[ -f "${CONFIG_DIR}/deploy_key" ]] && config_args+=(-C "$CONFIG_DIR" deploy_key)
        tar -czf "${dir}/config.tar.gz" "${config_args[@]}" 2>>"${SO_LOG_FILE:-/dev/null}" \
            && chmod 600 "${dir}/config.tar.gz" \
            || log_warn "Could not archive supabase/.env and installer config; continuing without it." >&2
    fi

    _backup_metadata_write "$dir" "$label"
    _backup_checksum_write "$dir"

    chmod 700 "$dir" 2>/dev/null || true
    log_ok "Backup created: ${dir} ($(du -h "${dir}/database.sql" 2>/dev/null | cut -f1))" >&2

    backup_prune_local
    printf '%s' "$dir"
    return 0
}

# ---------------------------------------------------------------------------
# Metadata and checksums - pure, file-only, no Docker
# ---------------------------------------------------------------------------

_backup_metadata_write() {
    local dir="$1" label="$2"
    {
        printf 'timestamp=%s\n'         "$(date -Is 2>/dev/null || date)"
        printf 'reason=%s\n'            "$label"
        printf 'scope=full\n'
        printf 'installer_version=%s\n' "$SO_INSTALLER_VERSION"
        printf 'supabase_version=%s\n'  "$(supabase_current_version)"
        printf 'app_commit=%s\n'        "$(state_get APP_COMMIT unknown)"
        printf 'app_branch=%s\n'        "$APP_BRANCH"
        printf 'app_image=%s\n'         "$(state_get APP_IMAGE unknown)"
        printf 'size_bytes=%s\n'        "$(stat -c%s "${dir}/database.sql" 2>/dev/null || printf '0')"
    } >"${dir}/metadata.txt"
}

# Write a sha256sum-compatible checksums.txt for every backup file present.
_backup_checksum_write() {
    local dir="$1" f hash
    : >"${dir}/checksums.txt"
    for f in database.sql "${BACKUP_ARCHIVE_FILES[@]}"; do
        [[ -f "${dir}/${f}" ]] || continue
        hash="$(file_sha256 "${dir}/${f}")" || continue
        printf '%s  %s\n' "$hash" "$f" >>"${dir}/checksums.txt"
    done
}

# Recompute every checksum in dir/checksums.txt and compare. Prints the first
# mismatching/missing file and returns non-zero on any failure.
_backup_checksum_verify() {
    local dir="$1" line hash file actual
    [[ -f "${dir}/checksums.txt" ]] || { log_error "No checksums.txt in ${dir}"; return 1; }
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        hash="${line%%  *}"
        file="${line#*  }"
        if [[ ! -f "${dir}/${file}" ]]; then
            log_error "Backup file missing: ${dir}/${file}"
            return 1
        fi
        actual="$(file_sha256 "${dir}/${file}")"
        if [[ "$actual" != "$hash" ]]; then
            log_error "Checksum mismatch for ${dir}/${file}"
            return 1
        fi
    done <"${dir}/checksums.txt"
    return 0
}

# ---------------------------------------------------------------------------
# Retention and listing - pure filesystem logic
# ---------------------------------------------------------------------------

# Keep only the most recent BACKUP_RETENTION_COUNT local backup cycles.
backup_prune_local() {
    local count old
    count="$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
    (( count > BACKUP_RETENTION_COUNT )) || return 0
    while IFS= read -r old; do
        log_debug "pruning old backup ${old}"
        rm -rf "$old"
    done < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort | head -n "$(( count - BACKUP_RETENTION_COUNT ))")
}

backup_latest() {
    find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | LC_ALL=C sort | tail -n1
}

# Print "dir|size|reason" for every local backup, newest first.
backup_list_entries() {
    local d
    find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | LC_ALL=C sort -r \
        | while IFS= read -r d; do
            [[ -n "$d" ]] || continue
            printf '%s|%s|%s\n' \
                "$d" \
                "$(du -h "${d}/database.sql" 2>/dev/null | cut -f1)" \
                "$(env_get "${d}/metadata.txt" reason 2>/dev/null || printf '-')"
        done
}

# ---------------------------------------------------------------------------
# Restore - the single implementation shared by local and restic-sourced
# restores (see cmd_restore in lib/commands/backup.sh)
# ---------------------------------------------------------------------------

# _restore_apply <dir> <scope: db|full>
#
# <dir> holds a backup in the layout backup_create_full() produces - either a
# local backup directory directly, or a staging directory restic just
# restored a snapshot into. Either way this is the only code that touches the
# live database/volumes/secrets during a restore.
_restore_apply() {
    local dir="$1" scope="${2:-db}"

    [[ -f "${dir}/database.sql" ]] || { log_error "No database.sql in ${dir}"; return 1; }
    _backup_checksum_verify "$dir" || die "Backup integrity check failed; refusing to restore from ${dir}."

    banner "Restore"
    printf '\n'
    cat "${dir}/metadata.txt" 2>/dev/null || true
    printf '\n'
    log_warn "This REPLACES the current database contents."
    [[ "$scope" == "full" ]] && log_warn "Scope 'full' also replaces Storage files and edge functions."
    confirm "Restore ${scope} from $(basename "$dir")?" n || { log_info "Cancelled."; return 0; }

    # Take a safety copy first: a restore that goes wrong should still be
    # recoverable.
    log_info "Creating a safety backup of the current state..."
    backup_create_full "pre-restore" >/dev/null || log_warn "Could not create a safety backup."

    supabase_check_postgres || die "The database is not running."

    log_info "Restoring the database..."
    local cid
    cid="$(_db_container)" || return 1
    if ! docker exec -i -e PGPASSWORD="$(_db_pass)" "$cid" \
            psql -U "$(_db_user)" -d "$(_db_name)" -q \
            <"${dir}/database.sql" >>"${SO_LOG_FILE:-/dev/null}" 2>&1; then
        die "Restore failed. See ${SO_LOG_FILE:-the log}."
    fi
    log_ok "Database restored from $(basename "$dir")"

    if [[ "$scope" == "full" ]]; then
        if [[ -f "${dir}/storage.tar.gz" ]]; then
            log_info "Restoring Storage files..."
            tar -xzf "${dir}/storage.tar.gz" -C "${SUPABASE_DIR}/volumes" \
                || log_warn "Could not restore the Storage volume."
        fi
        if [[ -f "${dir}/functions.tar.gz" ]]; then
            log_info "Restoring edge functions..."
            tar -xzf "${dir}/functions.tar.gz" -C "${SUPABASE_DIR}/volumes" \
                || log_warn "Could not restore the functions volume."
        fi
        if [[ -f "${dir}/config.tar.gz" ]]; then
            printf '\n'
            log_warn "config.tar.gz holds supabase/.env, installer.env and the deploy key."
            log_warn "Restoring it overwrites JWT_SECRET/POSTGRES_PASSWORD/API keys currently in use"
            log_warn "and invalidates every session and issued token."
            if confirm "Also restore supabase/.env and installer config from this backup?" n; then
                tar -xzf "${dir}/config.tar.gz" -C "$SUPABASE_DIR" .env 2>/dev/null
                tar -xzf "${dir}/config.tar.gz" -C "$CONFIG_DIR" installer.env 2>/dev/null
                tar -xzf "${dir}/config.tar.gz" -C "$CONFIG_DIR" deploy_key 2>/dev/null
                chmod 600 "${SUPABASE_DIR}/.env" "${CONFIG_DIR}/deploy_key" 2>/dev/null || true
                log_ok "Config restored. Re-run 'sentinel-ops update app' if SUPABASE_URL/keys changed."
            else
                log_info "Config left untouched."
            fi
        fi
    fi

    log_info "Restarting Supabase so every service reconnects..."
    supabase_restart || log_warn "Could not restart Supabase automatically."
    supabase_health_check 180 || log_warn "Supabase is not fully healthy after the restore."
    return 0
}
