#!/usr/bin/env bash
# lib/commands/maintenance.sh - rollback and logs.
#
# Backup/restore moved to lib/commands/backup.sh (lib/backup.sh has the
# underlying logic) - both feature the same "create a safety copy, then act"
# shape as rollback, but are a large enough surface (full-stack backups,
# restic replication) to warrant their own file.
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# Rollback
# ---------------------------------------------------------------------------

# Roll the application back to the previously deployed image and commit.
#
# The database is deliberately NOT rolled back automatically: a migration may
# have been applied that the old code still tolerates, and silently reverting
# schema is far more destructive than leaving it. The matching backup is named
# so an operator can restore it explicitly.
cmd_rollback() {
    require_root rollback
    installation_exists || die "No installation found at ${INSTALL_DIR}."
    config_load || true
    detect_compose >/dev/null 2>&1 || true
    SO_LOG_FILE="${LOG_DIR}/rollback-$(timestamp).log"

    local prev_image prev_commit
    prev_image="$(state_get PREVIOUS_APP_IMAGE '')"
    prev_commit="$(state_get PREVIOUS_APP_COMMIT '')"

    [[ -n "$prev_image" ]] || die "No previous image recorded; cannot roll back."
    docker image inspect "$prev_image" >/dev/null 2>&1 || \
        die "The previous image ${prev_image} is no longer present on this host."

    banner "Rollback"
    printf '\n'
    status_line "Current image" "" "$(state_get APP_IMAGE unknown)"
    status_line "Roll back to" "" "$prev_image"
    [[ -n "$prev_commit" ]] && status_line "Commit" "" "${prev_commit:0:7}"
    printf '\n'
    log_warn "Database migrations are NOT reverted."
    local latest
    latest="$(backup_latest)"
    [[ -n "$latest" ]] && log_info "Most recent backup: ${latest}"
    printf '\n'
    confirm "Proceed with the rollback?" n || { log_info "Cancelled."; return 0; }

    local current_image
    current_image="$(state_get APP_IMAGE '')"

    if frontend_run_container "$APP_CONTAINER_NAME" "$prev_image" "$APP_PORT" \
        && wait_for 90 3 frontend_check_http "$APP_PORT"; then
        state_set APP_IMAGE "$prev_image"
        state_set PREVIOUS_APP_IMAGE "$current_image"
        [[ -n "$prev_commit" ]] && state_set APP_COMMIT "$prev_commit"
        state_touch_updated
        log_ok "Rolled back to ${prev_image}"

        # Move the checkout back so the next update starts from the right base.
        if [[ -n "$prev_commit" ]] && repo_is_cloned; then
            if app_git checkout --quiet "$prev_commit" 2>/dev/null; then
                log_ok "Checkout moved to ${prev_commit:0:7} (detached HEAD)"
                log_info "Re-attach with: git -C ${APP_DIR} checkout ${APP_BRANCH}"
            else
                log_warn "Could not move the checkout to ${prev_commit:0:7}."
            fi
        fi
        return 0
    fi

    log_error "Rollback failed; the frontend is not healthy."
    return 1
}

# ---------------------------------------------------------------------------
# Logs
# ---------------------------------------------------------------------------

cmd_logs() {
    installation_exists || die "No installation found at ${INSTALL_DIR}."
    config_load || true
    detect_compose >/dev/null 2>&1 || true

    local target="${1:-app}" lines="${2:-100}"
    case "$target" in
        app|frontend)
            docker logs --tail "$lines" -f "$APP_CONTAINER_NAME" 2>&1
            ;;
        supabase)
            supabase_compose logs --tail "$lines" -f
            ;;
        logflare|analytics)
            supabase_compose logs --tail "$lines" -f analytics
            ;;
        installer)
            local latest
            # By modification time, not by name: the filenames are prefixed with
            # the operation (install-, update-app-, rollback-), so sorting them
            # alphabetically returns whichever prefix sorts last rather than the
            # log that was actually written most recently.
            latest="$(find "$LOG_DIR" -name '*.log' -type f -printf '%T@ %p\n' 2>/dev/null \
                        | sort -n | tail -n1 | cut -d' ' -f2-)"
            [[ -n "$latest" ]] || die "No installer logs yet."
            printf '%s\n\n' "$latest"
            tail -n "$lines" "$latest"
            ;;
        *)
            log_error "Unknown log target: ${target}"
            printf 'Valid: app, supabase, logflare, installer\n'
            return 2
            ;;
    esac
}
