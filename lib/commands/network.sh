#!/usr/bin/env bash
# lib/commands/network.sh - expose (or restrict) the stack on the network.
#
# By default the frontend binds to 127.0.0.1 (APP_BIND) and is reachable only
# through whatever reverse proxy the operator puts in front of it. Supabase's
# own compose file is different: its gateway publishes to every interface
# unconditionally (upstream's own choice, not this installer's), so the host
# firewall is the only thing standing between it and the internet - see the
# README's "Firewall" section.
#
# This command is for operators who have no reverse proxy yet (or are testing
# on a private network) and want direct access. It is not the recommended
# long-term setup: there is no TLS on either port.
# shellcheck shell=bash

network_prompt_config() {
    section "Public Network Access"
    printf 'By default the frontend only listens on 127.0.0.1, reachable through a\n'
    printf 'reverse proxy you run on this host. Supabase'"'"'s own gateway always binds\n'
    printf 'every interface (upstream'"'"'s choice); the firewall is what keeps it private.\n\n'
    printf 'Enable this only if you have no reverse proxy yet and accept there is no\n'
    printf 'TLS on these ports. You can change this later with: sentinel-ops network\n\n'

    if confirm "Expose the frontend and Supabase API directly to the network now?" n; then
        APP_BIND="0.0.0.0"
    else
        APP_BIND="127.0.0.1"
    fi
}

# Open the ports implied by the current configuration. Called from a fresh
# install (after Supabase's .env exists, so the Kong/gateway port is known) and
# from `network enable`.
network_apply_firewall() {
    [[ "$APP_BIND" == "0.0.0.0" ]] || { log_debug "Public access not requested; firewall left untouched."; return 0; }
    firewall_open_port "$APP_PORT" || log_warn "Could not open ${APP_PORT}/tcp automatically."
    if supabase_installed; then
        firewall_open_port "$(supabase_kong_port)" || log_warn "Could not open $(supabase_kong_port)/tcp automatically."
    fi
    return 0
}

_network_status() {
    section "Network Exposure"
    if [[ "$APP_BIND" == "0.0.0.0" ]]; then
        status_line "Frontend" "warn" "Public (0.0.0.0:${APP_PORT})"
    else
        status_line "Frontend" "ok" "Loopback only (${APP_BIND:-127.0.0.1}:${APP_PORT})"
    fi
    if supabase_installed; then
        status_line "Supabase gateway" "warn" "Always public upstream (0.0.0.0:$(supabase_kong_port)) - the firewall is what protects it"
    fi
    firewall_detect >/dev/null
    if firewall_active; then
        status_line "Firewall" "ok" "${FIREWALL_BACKEND} active"
    else
        status_line "Firewall" "bad" "${FIREWALL_BACKEND} $([[ "$FIREWALL_BACKEND" == "none" ]] && printf 'not found' || printf 'installed, inactive')"
    fi
    return 0
}

_network_enable() {
    log_warn "This exposes the frontend and Supabase API directly, with no TLS and no reverse proxy."
    log_warn "Anything that can reach this host on these ports can reach the application and the database API."

    # confirm() takes the default under --yes, and "n" is the safe default
    # here - so --yes would never approve this otherwise. Mirror nuke's own
    # confirmation, which honours --yes explicitly for exactly this reason.
    if [[ "$SO_ASSUME_YES" == "true" ]]; then
        log_warn "--yes given; proceeding without confirmation."
    else
        confirm "Continue?" n || { log_info "Cancelled."; return 0; }
    fi

    APP_BIND="0.0.0.0"
    config_save
    network_apply_firewall

    if container_exists "$APP_CONTAINER_NAME"; then
        log_info "Restarting the frontend bound to 0.0.0.0..."
        if frontend_run_container "$APP_CONTAINER_NAME" "$(frontend_deployed_image)" "$APP_PORT" \
            && wait_for 60 3 frontend_check_http "$APP_PORT"; then
            log_ok "Frontend reachable on 0.0.0.0:${APP_PORT}"
        else
            log_error "Frontend restart failed; check: sentinel-ops logs app"
            return 1
        fi
    fi
    printf '\n'
    log_ok "Public access enabled."
    log_warn "Make sure nothing beyond ports 22/${APP_PORT}/$(supabase_kong_port 2>/dev/null || printf 8000) is open on this host's edge."
    return 0
}

_network_disable() {
    APP_BIND="127.0.0.1"
    config_save

    if container_exists "$APP_CONTAINER_NAME"; then
        log_info "Restarting the frontend bound to loopback..."
        frontend_run_container "$APP_CONTAINER_NAME" "$(frontend_deployed_image)" "$APP_PORT" \
            && wait_for 60 3 frontend_check_http "$APP_PORT"
    fi
    firewall_close_port "$APP_PORT"

    log_ok "Frontend restricted back to 127.0.0.1."
    log_warn "Supabase's gateway (port $(supabase_kong_port 2>/dev/null || printf 8000)) still binds every interface -"
    log_warn "that is upstream's own compose file, not something this installer controls."
    log_warn "Close it at the firewall by hand if you no longer want it reachable."
    return 0
}

cmd_network() {
    require_root network
    installation_exists || die "No installation found at ${INSTALL_DIR}."
    config_load || true
    detect_compose >/dev/null 2>&1 || true
    detect_os >/dev/null 2>&1 || true

    banner "Network Exposure"
    printf '\n'

    case "${1:-status}" in
        status)  _network_status ;;
        enable)  _network_enable ;;
        disable) _network_disable ;;
        *)
            log_error "Unknown network subcommand: $1"
            printf 'Valid: status, enable, disable\n'
            return 2
            ;;
    esac
}
