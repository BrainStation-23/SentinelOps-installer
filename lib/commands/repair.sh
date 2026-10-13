#!/usr/bin/env bash
# lib/commands/repair.sh - validate supabase/.env for known-mechanical
# mistakes (CRLF, stray whitespace around "=", duplicate keys, a trailing
# slash on a public URL), auto-fix them, re-wire Azure AD if it drifted back
# to upstream's broken default, re-apply the database grant backup restore
# needs, and restart what needs it. A container has
# already loaded its environment; editing the file alone changes nothing
# until it is recreated.
# shellcheck shell=bash

_repair_check() {
    section "supabase/.env"
    local issues
    issues="$(env_lint "${SUPABASE_DIR}/.env")"
    if [[ -z "$issues" ]]; then
        status_line "Status" "ok" "No known problems found"
    else
        status_line "Status" "warn" "Problems found"
        while IFS= read -r line; do
            printf '  - %s\n' "$line"
        done <<<"$issues"
        printf '\nRun `sentinel-ops repair apply` to fix these and restart the affected services.\n'
    fi
    _repair_check_database
    return 0
}

# Backup restore inside the application needs the migration role to be allowed
# to set session_replication_role; see db_ensure_replication_role_grant.
_repair_check_database() {
    section "Database"
    if ! _db_container >/dev/null 2>&1; then
        status_line "Restore grant" "warn" "Database container not running; not checked"
        return 0
    fi
    case "$(db_replication_role_status 2>/dev/null)" in
        true)        status_line "Restore grant" "ok"   "$(_db_user) may set session_replication_role" ;;
        false)       status_line "Restore grant" "warn" "Missing; backup restore will fail. Run: sentinel-ops repair apply" ;;
        unsupported) status_line "Restore grant" "warn" "PostgreSQL older than 15; backup restore will fail" ;;
        *)           status_line "Restore grant" "warn" "Could not be checked" ;;
    esac
}

_repair_apply() {
    local env_file="${SUPABASE_DIR}/.env"
    local changed="false"

    if env_repair_file "$env_file"; then
        changed="true"
        log_ok "Fixed formatting/value problems in supabase/.env (backup saved alongside it)"
    else
        log_ok "supabase/.env: no known problems found"
    fi

    if [[ "$ENABLE_AZURE_AD" == "true" ]]; then
        local compose="${SUPABASE_DIR}/docker-compose.yml"
        local before
        before="$(cat "$compose" 2>/dev/null || true)"
        azure_patch_compose || log_warn "Azure AD wiring could not be re-applied; see the warning above."
        if [[ -f "$compose" && "$before" != "$(cat "$compose")" ]]; then
            changed="true"
            log_ok "Re-wired Azure AD sign-in in docker-compose.yml"
        fi
    fi

    # The same drift for auth hardening: a reset COMPOSE_FILE silently drops the
    # overlay, and a hand-edited installer.env needs applying.
    local before_hardening
    before_hardening="$(_hardening_fingerprint)"
    hardening_apply_config >/dev/null || log_warn "The auth hardening configuration could not be re-applied."
    if [[ "$before_hardening" != "$(_hardening_fingerprint)" ]]; then
        changed="true"
        log_ok "Re-applied the auth hardening configuration"
    fi

    # A database grant takes effect immediately; it needs no restart.
    if _db_container >/dev/null 2>&1; then
        db_ensure_replication_role_grant || true
    else
        log_warn "The database container is not running; skipped the backup restore grant."
    fi

    if [[ "$changed" != "true" ]]; then
        log_info "Nothing to restart."
        return 0
    fi

    log_info "Restarting the services that read supabase/.env so the fixes take effect..."
    if run_logged "restart gateway/auth" bash -c \
            "$(_supabase_compose_cmd) up -d --force-recreate $(supabase_gateway_service) auth"; then
        wait_for 60 5 supabase_check_auth && log_ok "Auth healthy" \
            || log_warn "Auth did not answer its health check; check: sentinel-ops logs supabase"
    else
        log_warn "Could not restart automatically; restart Supabase manually: sentinel-ops update supabase"
    fi
    return 0
}

cmd_repair() {
    require_root repair
    installation_exists || die "No installation found at ${INSTALL_DIR}."
    config_load || true
    detect_compose >/dev/null 2>&1 || true
    supabase_installed || die "Supabase is not installed at ${SUPABASE_DIR}."

    banner "Repair"
    printf '\n'

    case "${1:-check}" in
        check) _repair_check ;;
        apply) _repair_apply ;;
        *)
            log_error "Unknown repair subcommand: $1"
            printf 'Valid: check, apply\n'
            return 2
            ;;
    esac
}
