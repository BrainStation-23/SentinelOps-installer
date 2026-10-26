#!/usr/bin/env bash
# lib/commands/cleanup.sh - remove superseded Docker images on demand.
#
# `update app` and `update supabase` already do this after every successful
# run (lib/images.sh). This is for an installation that built up images before
# that existed, for an operator who turned it off, and for a dry run to see
# what would go.
# shellcheck shell=bash

cmd_cleanup() {
    require_root cleanup
    installation_exists || die "No installation found at ${INSTALL_DIR}."
    config_load || true
    detect_compose >/dev/null 2>&1 || true
    docker_daemon_ok || die "Docker is not available."

    case "${1:-}" in
        ""|run)       SO_IMAGES_DRY_RUN="false" ;;
        --dry-run|-n) SO_IMAGES_DRY_RUN="true" ;;
        *)
            log_error "Unknown cleanup option: $1"
            printf 'Usage: sentinel-ops cleanup [--dry-run]\n'
            return 2
            ;;
    esac

    # An update half way through a build or a deployment must not have its
    # images removed from under it.
    update_lock_or_die
    SO_LOG_FILE="${LOG_DIR}/cleanup-$(timestamp).log"

    banner "Clean up Docker images"
    printf '\n'
    [[ "$SO_IMAGES_DRY_RUN" == "true" ]] && log_info "Dry run: nothing will be removed."
    status_line "Images before" "" "$(images_disk_usage)"
    printf '\n'

    images_prune_app
    if supabase_installed; then
        images_prune_supabase
    fi
    images_prune_build_cache

    if [[ "$SO_IMAGES_DRY_RUN" != "true" ]]; then
        printf '\n'
        status_line "Images now" "" "$(images_disk_usage)"
    fi
    printf '\n'
    return 0
}
