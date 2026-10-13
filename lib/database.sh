#!/usr/bin/env bash
# lib/database.sh - low-level database access, migrations and edge functions.
#
# Full-stack backup/restore lives in lib/backup.sh, which calls the
# _db_container/_db_user/_db_pass helpers below - it is not a database-only
# concern any more (it also archives Storage, edge functions and config).
#
# These operations are shared verbatim by first install, application update and
# full update. There is exactly one implementation of each.
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# Low-level database access
# ---------------------------------------------------------------------------

_db_container() {
    local cid
    cid="$(supabase_container_id "$(supabase_db_service)")"
    [[ -n "$cid" ]] || { log_error "The Supabase database container is not running."; return 1; }
    printf '%s' "$cid"
}

_db_user() { env_get "${SUPABASE_DIR}/.env" POSTGRES_USER 2>/dev/null || printf 'postgres'; }
_db_name() { env_get "${SUPABASE_DIR}/.env" POSTGRES_DB   2>/dev/null || printf 'postgres'; }
_db_pass() { env_get "${SUPABASE_DIR}/.env" POSTGRES_PASSWORD 2>/dev/null || printf ''; }

# The bootstrap superuser of the self-hosted Supabase image. Its password is
# POSTGRES_PASSWORD, like every other role the image creates.
DB_SUPERUSER="supabase_admin"

# Run SQL from stdin inside the database container, as the given role.
_db_psql_as() {
    local user="$1"; shift
    local cid
    cid="$(_db_container)" || return 1
    docker exec -i -e PGPASSWORD="$(_db_pass)" "$cid" \
        psql -U "$user" -d "$(_db_name)" -v ON_ERROR_STOP=1 "$@"
}

# Run SQL from stdin inside the database container.
db_psql() {
    _db_psql_as "$(_db_user)" "$@"
}

# Run SQL from stdin as the superuser. Reserved for the few grants the
# migration role cannot give itself; everything else runs through db_psql so
# the objects it creates stay owned by the migration role.
db_psql_superuser() {
    _db_psql_as "$DB_SUPERUSER" "$@"
}

# Run a single query and print the bare result.
db_query() {
    printf '%s' "$1" | db_psql -tAq 2>/dev/null
}

_sql_ident() { printf '"%s"' "${1//\"/\"\"}"; }

# Does the migration role hold SET on session_replication_role? Prints
# "true", "false", or "unsupported" before PostgreSQL 15, where per-parameter
# grants do not exist.
db_replication_role_status() {
    local ver
    ver="$(db_query "SHOW server_version_num;")" || return 1
    [[ "$ver" =~ ^[0-9]+$ ]] || return 1
    if (( ver < 150000 )); then
        printf 'unsupported'
        return 0
    fi
    local has
    has="$(db_query "SELECT has_parameter_privilege(current_user, 'session_replication_role', 'SET');")" || return 1
    case "$has" in
        t) printf 'true' ;;
        f) printf 'false' ;;
        *) return 1 ;;
    esac
}

# Let the migration role set session_replication_role. The application's
# restore loads tables with foreign keys and triggers suspended, and on a
# self-hosted stack the migration role (postgres) is not a superuser, so it
# needs this one grant - which only the superuser can give. Idempotent.
#
# Never fails the caller's run: a missing grant breaks backup restore inside
# the application, not the deployment, so it is reported loudly instead.
db_ensure_replication_role_grant() {
    local status
    if ! status="$(db_replication_role_status)"; then
        log_warn "Could not check whether $(_db_user) may set session_replication_role."
        return 1
    fi

    case "$status" in
        true)
            log_debug "$(_db_user) may already set session_replication_role"
            return 0
            ;;
        unsupported)
            log_warn "PostgreSQL is older than 15; cannot grant SET on session_replication_role."
            log_warn "Restoring a backup from inside the application will fail."
            return 1
            ;;
    esac

    if printf 'GRANT SET ON PARAMETER session_replication_role TO %s;\n' "$(_sql_ident "$(_db_user)")" \
            | db_psql_superuser -q >>"${SO_LOG_FILE:-/dev/null}" 2>&1 \
        && [[ "$(db_replication_role_status)" == "true" ]]; then
        log_ok "Granted $(_db_user) SET on session_replication_role (needed by backup restore)"
        return 0
    fi

    log_warn "Could not grant $(_db_user) SET on session_replication_role as ${DB_SUPERUSER}."
    log_warn "Restoring a backup from inside the application will fail until it is granted."
    log_warn "Retry with: sentinel-ops repair apply"
    return 1
}

# ---------------------------------------------------------------------------
# Migrations
#
# The tracking table is the same one the Supabase CLI uses
# (supabase_migrations.schema_migrations), so a database migrated by this
# installer stays compatible with `supabase db push` and vice versa.
# ---------------------------------------------------------------------------

_migrations_ensure_table() {
    db_psql -q <<'SQL' >/dev/null 2>&1
CREATE SCHEMA IF NOT EXISTS supabase_migrations;
CREATE TABLE IF NOT EXISTS supabase_migrations.schema_migrations (
    version    text NOT NULL PRIMARY KEY,
    statements text[],
    name       text
);
SQL
}

# The version is the leading numeric timestamp of the filename, matching the
# Supabase CLI's convention: 20240101120000_add_users.sql -> 20240101120000
_migration_version() {
    local base="$1"
    base="${base%.sql}"
    printf '%s' "${base%%_*}"
}

_migration_name() {
    local base="$1"
    base="${base%.sql}"
    if [[ "$base" == *_* ]]; then printf '%s' "${base#*_}"; else printf '%s' "$base"; fi
}

_sql_quote() { printf "%s" "${1//\'/\'\'}"; }

# Apply every pending migration, in filename order.
#
# Each migration runs in a single transaction together with the row that
# records it, so a failed migration leaves neither partial schema changes nor a
# bogus tracking entry.
deploy_migrations() {
    local dir="${APP_DIR}/supabase/migrations"
    [[ -d "$dir" ]] || { log_error "No migrations directory at ${dir}"; return 1; }

    _db_container >/dev/null || return 1

    if ! _migrations_ensure_table; then
        log_error "Could not create the migration tracking table."
        return 1
    fi

    # Before the early return below, so an already-current database still gets
    # it. Not fatal: see db_ensure_replication_role_grant.
    db_ensure_replication_role_grant || true

    local applied_list
    applied_list="$(db_query "SELECT version FROM supabase_migrations.schema_migrations;")" || applied_list=""

    local files=() f
    while IFS= read -r f; do files+=("$f"); done < <(find "$dir" -maxdepth 1 -name '*.sql' -type f | LC_ALL=C sort)

    if (( ${#files[@]} == 0 )); then
        log_warn "No migration files found in ${dir}"
        return 0
    fi

    local pending=() base version
    for f in "${files[@]}"; do
        base="$(basename "$f")"
        version="$(_migration_version "$base")"
        if printf '%s\n' "$applied_list" | grep -qx "$version"; then
            log_debug "already applied: ${base}"
        else
            pending+=("$f")
        fi
    done

    if (( ${#pending[@]} == 0 )); then
        log_ok "Database schema up to date (${#files[@]} migrations already applied)"
        return 0
    fi

    log_info "Applying ${#pending[@]} pending migration(s)..."
    local count=0
    for f in "${pending[@]}"; do
        base="$(basename "$f")"
        version="$(_migration_version "$base")"
        local name
        name="$(_migration_name "$base")"

        log_info "  ${base}"
        if ! {
                cat "$f"
                printf '\nINSERT INTO supabase_migrations.schema_migrations (version, name) VALUES (%s%s%s, %s%s%s);\n' \
                    "'" "$(_sql_quote "$version")" "'" "'" "$(_sql_quote "$name")" "'"
            } | db_psql --single-transaction -q >>"${SO_LOG_FILE:-/dev/null}" 2>&1; then
            log_error "Migration failed: ${base}"
            log_error "The transaction was rolled back; the database is unchanged by this migration."
            log_error "Applied before the failure: ${count} migration(s)."
            return 1
        fi
        count=$(( count + 1 ))
    done

    log_ok "Applied ${count} migration(s)"
    return 0
}

migrations_applied_count() {
    db_query "SELECT count(*) FROM supabase_migrations.schema_migrations;" 2>/dev/null || printf '?'
}

# ---------------------------------------------------------------------------
# Edge functions
#
# On a self-hosted stack the edge runtime serves whatever is mounted at
# supabase/volumes/functions. Deploying therefore means syncing the repository's
# functions into that volume and restarting the runtime - `supabase functions
# deploy` targets the hosted platform and does not apply here.
# ---------------------------------------------------------------------------

_functions_service() {
    local s
    for s in functions edge-runtime deno-relay; do
        if supabase_compose config --services 2>/dev/null | grep -qx "$s"; then
            printf '%s' "$s"; return 0
        fi
    done
    printf 'functions'
}

deploy_functions() {
    local src="${APP_DIR}/supabase/functions"
    local dest="${SUPABASE_DIR}/volumes/functions"

    [[ -d "$src" ]] || { log_error "No functions directory at ${src}"; return 1; }
    mkdir -p "$dest"

    # Enumerate the functions: every immediate subdirectory holding an entry
    # point. Directories starting with _ are shared code, not functions.
    local names=() d base
    while IFS= read -r d; do
        base="$(basename "$d")"
        [[ "$base" == _* ]] && continue
        if [[ -f "${d}/index.ts" || -f "${d}/index.js" || -f "${d}/mod.ts" ]]; then
            names+=("$base")
        fi
    done < <(find "$src" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort)

    if (( ${#names[@]} == 0 )); then
        log_warn "No deployable edge functions found in ${src}"
    else
        log_info "Deploying ${#names[@]} edge function(s): ${names[*]}"
    fi

    # The stack ships a `main` bootstrap function that routes requests to the
    # others. It is infrastructure, not application code, so it is preserved.
    local preserved=""
    if [[ -d "${dest}/main" && ! -d "${src}/main" ]]; then
        preserved="$(mktemp -d)"
        cp -a "${dest}/main" "${preserved}/main"
    fi

    # Replace the application functions wholesale so a function deleted from
    # the repository also disappears from the deployment.
    local keep
    for d in "$dest"/*/; do
        [[ -d "$d" ]] || continue
        keep="$(basename "$d")"
        [[ "$keep" == "main" ]] && continue
        rm -rf "$d"
    done

    cp -a "${src}/." "${dest}/" || { log_error "Could not copy functions into ${dest}"; return 1; }

    if [[ -n "$preserved" && -d "${preserved}/main" && ! -d "${dest}/main" ]]; then
        cp -a "${preserved}/main" "${dest}/main"
    fi
    [[ -n "$preserved" ]] && rm -rf "$preserved"

    # Restart the runtime so it picks up the new code.
    local svc
    svc="$(_functions_service)"
    log_info "Restarting the edge runtime (${svc})..."
    if ! run_logged "restart ${svc}" bash -c \
        "$(_supabase_compose_cmd) up -d --force-recreate ${svc}"; then
        log_error "Could not restart the edge runtime."
        return 1
    fi

    # Confirm it actually came back up; a syntax error in a function can stop
    # the runtime from booting at all.
    if ! wait_for 60 3 supabase_service_running "$svc"; then
        log_error "The edge runtime did not stay running after deployment."
        docker logs --tail 40 "$(supabase_container_id "$svc")" 2>&1 | tail -n 40 >&2 || true
        return 1
    fi

    state_set APP_FUNCTIONS "${names[*]:-none}"
    log_ok "Edge functions deployed"
    return 0
}
