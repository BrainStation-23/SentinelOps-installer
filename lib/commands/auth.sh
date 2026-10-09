#!/usr/bin/env bash
# lib/commands/auth.sh - turn the optional Supabase Auth hardening settings on
# or off after install, without a full reinstall. See lib/hardening.sh.
# shellcheck shell=bash

_auth_status() {
    section "Auth hardening"
    hardening_status
    printf '\nChange with: sentinel-ops auth enable|disable <%s>\n' "$(_hardening_feature_list)"
    return 0
}

# Recreate the auth container (and the frontend, when the CAPTCHA site key it
# serves to the browser changed) so the new environment is actually loaded.
_auth_restart() {
    local feature="$1"
    log_info "Restarting the auth service to pick up the new configuration..."
    if run_logged "restart auth" bash -c "$(_supabase_compose_cmd) up -d --force-recreate auth"; then
        wait_for 60 5 supabase_check_auth && log_ok "Auth service healthy" \
            || log_warn "Auth did not answer its health check after restarting; check: sentinel-ops logs supabase"
    else
        log_error "Could not restart the auth service."
        return 1
    fi

    if [[ "$feature" == "captcha" ]]; then
        local image
        image="$(frontend_deployed_image)"
        if [[ -n "$image" ]] && container_exists "$APP_CONTAINER_NAME"; then
            log_info "Restarting the frontend so it serves the CAPTCHA site key..."
            if frontend_run_container "$APP_CONTAINER_NAME" "$image" "$APP_PORT" \
                    && wait_for 90 3 frontend_check_http "$APP_PORT"; then
                log_ok "Frontend restarted"
            else
                log_warn "The frontend did not come back cleanly; check: sentinel-ops logs app"
            fi
        fi
    fi
    return 0
}

_auth_set() {
    local action="$1" feature="${2:-}"
    if [[ -z "$feature" ]] || ! hardening_feature_known "$feature"; then
        [[ -n "$feature" ]] && log_error "Unknown feature: ${feature}"
        log_error "Usage: sentinel-ops auth ${action} <$(_hardening_feature_list)>"
        return 2
    fi

    if [[ "$action" == "enable" ]]; then
        hardening_enable_feature "$feature" || { log_info "Not enabling ${feature}."; return 0; }
    else
        hardening_disable_feature "$feature" || return 2
        # hardening_apply_config only ever turns sign-up off; turning it back
        # on is this explicit command's job.
        if [[ "$feature" == "signup" ]]; then
            env_set "${SUPABASE_DIR}/.env" DISABLE_SIGNUP "false"
        fi
    fi

    config_save
    hardening_apply_config || die "Could not write the auth hardening configuration."
    _auth_restart "$feature" || return 1

    printf '\n'
    log_ok "${feature}: $([[ "$action" == "enable" ]] && printf enabled || printf disabled)"
    return 0
}

cmd_auth() {
    require_root auth
    installation_exists || die "No installation found at ${INSTALL_DIR}."
    config_load || true
    detect_compose >/dev/null 2>&1 || true
    supabase_installed || die "Supabase is not installed at ${SUPABASE_DIR}."

    banner "Auth Hardening"
    printf '\n'

    case "${1:-status}" in
        status)         _auth_status ;;
        enable|disable) _auth_set "$1" "${2:-}" ;;
        *)
            log_error "Unknown auth subcommand: $1"
            printf 'Valid: status, enable <feature>, disable <feature>\n'
            return 2
            ;;
    esac
}
