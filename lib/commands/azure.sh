#!/usr/bin/env bash
# lib/commands/azure.sh - configure or reconfigure Azure AD sign-in after
# install, without a full reinstall.
# shellcheck shell=bash

_azure_status() {
    section "Azure AD (Microsoft Entra ID)"
    if [[ "$ENABLE_AZURE_AD" == "true" ]]; then
        status_line "Status" "ok" "Enabled"
        status_line "Client ID" "" "${AZURE_CLIENT_ID:-(not set)}"
        status_line "Tenant" "" "${AZURE_TENANT_ID:-common (any organization)}"
        status_line "Redirect URI" "" "$(_azure_redirect_uri)"
    else
        status_line "Status" "warn" "Disabled"
    fi
    return 0
}

_azure_enable() {
    azure_prompt_config
    if [[ "$ENABLE_AZURE_AD" != "true" ]]; then
        log_info "Not enabling Azure AD sign-in."
        return 0
    fi

    config_save
    azure_apply_config    || die "Could not write the Azure AD configuration."
    azure_patch_compose   || log_warn "Azure AD is configured but not fully wired; see the warning above."

    log_info "Restarting the auth service to pick up the new configuration..."
    if run_logged "restart auth" bash -c "$(_supabase_compose_cmd) up -d --force-recreate auth"; then
        wait_for 60 5 supabase_check_auth && log_ok "Auth service healthy" \
            || log_warn "Auth did not answer its health check after restarting; check: sentinel-ops logs supabase"
    else
        log_error "Could not restart the auth service."
        return 1
    fi

    printf '\n'
    log_ok "Azure AD sign-in enabled."
    status_line "Redirect URI" "" "$(_azure_redirect_uri)"
    printf '\nMake sure this exact redirect URI is registered on the app registration in Entra ID.\n\n'
    return 0
}

_azure_disable() {
    ENABLE_AZURE_AD="false"
    config_save
    azure_apply_config || die "Could not update the Azure AD configuration."

    log_info "Restarting the auth service..."
    run_logged "restart auth" bash -c "$(_supabase_compose_cmd) up -d --force-recreate auth" \
        || log_warn "Could not restart the auth service automatically."

    log_ok "Azure AD sign-in disabled."
    return 0
}

cmd_azure() {
    require_root azure
    installation_exists || die "No installation found at ${INSTALL_DIR}."
    config_load || true
    detect_compose >/dev/null 2>&1 || true
    supabase_installed || die "Supabase is not installed at ${SUPABASE_DIR}."

    banner "Azure AD Sign-In"
    printf '\n'

    case "${1:-status}" in
        status)  _azure_status ;;
        enable)  _azure_enable ;;
        disable) _azure_disable ;;
        *)
            log_error "Unknown azure subcommand: $1"
            printf 'Valid: status, enable, disable\n'
            return 2
            ;;
    esac
}
