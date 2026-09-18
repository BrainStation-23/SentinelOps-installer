#!/usr/bin/env bash
# lib/menu.sh - the guided interface.
#
# The menu is a thin layer over the same commands the CLI exposes, so anything
# done here can also be scripted.
# shellcheck shell=bash

_menu_installed() {
    banner "Sentinel Ops Installer"
    printf '\n'
    printf 'Installation detected.  (%s)\n\n' "$INSTALL_DIR"
    printf '  1. Update Sentinel Ops\n'
    printf '  2. Update Supabase\n'
    printf '  3. Update Everything\n'
    printf '  4. System Status\n'
    printf '  5. Credentials\n'
    printf '  6. Backup now (full-stack)\n'
    printf '  7. Rollback application\n'
    printf '  8. Network exposure (LAN access)\n'
    printf '  9. Point at a real domain\n'
    printf ' 10. Offsite/secondary backup (3-2-1)\n'
    printf ' 11. Backup schedule\n'
    printf ' 12. Azure AD sign-in\n'
    printf ' 13. Destroy this installation (nuke)\n'
    printf ' 14. Exit\n\n'
    printf 'Select: '
}

_menu_fresh() {
    banner "Sentinel Ops Installer"
    printf '\n'
    printf 'No existing installation detected.\n\n'
    printf '  1. Install Sentinel Ops\n'
    printf '  2. Exit\n\n'
    printf 'Select: '
}

cmd_menu() {
    # A menu needs a terminal. Without one, say what to run instead of looping
    # forever on EOF.
    if [[ ! -t 0 ]]; then
        log_error "The interactive menu needs a terminal."
        printf 'Use a subcommand instead, for example:\n'
        printf '  sentinel-ops install --yes\n  sentinel-ops status\n'
        return 2
    fi

    local choice domain_choice
    while true; do
        if installation_exists; then
            _menu_installed
            IFS= read -r choice || return 0
            case "$choice" in
                1) cmd_update_app       || true ;;
                2) cmd_update_supabase  || true ;;
                3) cmd_update_all       || true ;;
                4) cmd_status           || true ;;
                5) cmd_credentials      || true ;;
                6) cmd_backup create    || true ;;
                7) cmd_rollback         || true ;;
                8) cmd_network          || true ;;
                9)
                    printf 'Domain (e.g. app.example.com): '
                    IFS= read -r domain_choice || domain_choice=""
                    [[ -n "$domain_choice" ]] && cmd_domain set "$domain_choice"
                    ;;
                10) cmd_remote status   || true ;;
                11) cmd_schedule status || true ;;
                12) cmd_azure           || true ;;
                13) cmd_nuke            || true ;;
                14|q|quit|exit) return 0 ;;
                *) log_warn "Invalid selection: ${choice}" ;;
            esac
        else
            _menu_fresh
            IFS= read -r choice || return 0
            case "$choice" in
                1) cmd_install || true ;;
                2|q|quit|exit) return 0 ;;
                *) log_warn "Invalid selection: ${choice}" ;;
            esac
        fi
        printf '\nPress Enter to return to the menu...'
        IFS= read -r _ || return 0
        printf '\n'
    done
}
