#!/usr/bin/env bash
# lib/prereqs.sh - base tooling, Docker engine and Docker Compose.
# shellcheck shell=bash

# Set by detect_compose(): the command used to drive compose files.
DOCKER_COMPOSE_CMD=()

# Map a generic tool name to the package that provides it on this family.
_package_for() {
    local tool="$1"
    case "$tool" in
        ssh)
            [[ "$OS_FAMILY" == "debian" ]] && printf 'openssh-client' || printf 'openssh-clients'
            ;;
        *) printf '%s' "$tool" ;;
    esac
}

# Verify the base CLI tools, installing whatever is missing.
install_base_prerequisites() {
    local tools=(curl git openssl jq ssh)
    local missing=() pkgs=() tool

    for tool in "${tools[@]}"; do
        if have_cmd "$tool"; then
            log_ok "${tool} present"
        else
            missing+=("$tool")
        fi
    done

    if (( ${#missing[@]} == 0 )); then
        return 0
    fi

    log_info "Installing missing prerequisites: ${missing[*]}"
    for tool in "${missing[@]}"; do
        pkgs+=("$(_package_for "$tool")")
    done

    if ! pkg_install "${pkgs[@]}"; then
        log_error "Failed to install: ${pkgs[*]}"
        log_error "Install them manually and re-run the installer."
        return 1
    fi

    # Re-verify: a package manager can report success while still not providing
    # the binary we actually need.
    local still_missing=()
    for tool in "${missing[@]}"; do
        have_cmd "$tool" || still_missing+=("$tool")
    done
    if (( ${#still_missing[@]} )); then
        log_error "Still missing after installation: ${still_missing[*]}"
        return 1
    fi

    log_ok "Prerequisites installed"
    return 0
}

# ---------------------------------------------------------------------------
# Docker
# ---------------------------------------------------------------------------

# Docker is verified at three levels, because `docker --version` succeeding
# tells us nothing about whether the daemon is usable:
#   1. the client binary exists
#   2. the daemon answers (`docker info`)
#   3. compose v2 is available
# The binary must exist *and* actually run.
#
# `have_cmd docker` alone is not enough. On WSL with Windows PATH interop a
# Docker Desktop docker.exe sits on PATH but cannot work inside the distro
# unless WSL integration is enabled: it exits non-zero with an explanatory
# message instead of printing a version. The installer would then report
# "Docker installed ()" - note the empty parentheses - skip installing Docker,
# and fail later on the daemon check with no hint as to the real cause.
docker_binary_ok() {
    have_cmd docker || return 1
    docker --version >/dev/null 2>&1
}

# True when the docker on PATH is a Windows executable reached through WSL
# interop rather than a Linux client.
docker_is_windows_shim() {
    local path
    path="$(command -v docker 2>/dev/null)" || return 1
    [[ "$path" == /mnt/* || "$path" == *.exe ]]
}

docker_daemon_ok() { docker info >/dev/null 2>&1; }

detect_compose() {
    if docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD=(docker compose)
        return 0
    fi
    if have_cmd docker-compose && docker-compose version >/dev/null 2>&1; then
        # Legacy v1. Usable, but several Supabase compose files rely on v2
        # syntax, so warn loudly.
        DOCKER_COMPOSE_CMD=(docker-compose)
        log_warn "Using legacy docker-compose v1. Docker Compose v2 is strongly recommended."
        return 0
    fi
    DOCKER_COMPOSE_CMD=()
    return 1
}

install_docker() {
    log_info "Installing Docker..."

    # Use Docker's official convenience script: it configures the upstream
    # repository correctly for every distribution we support, which is far more
    # reliable than hand-rolling per-distro repo files.
    local script
    script="$(mktemp)"
    if ! run_logged "download get.docker.com" curl -fsSL https://get.docker.com -o "$script"; then
        rm -f "$script"
        log_error "Could not download the Docker installation script."
        return 1
    fi
    if ! run_logged "Docker installation" sh "$script"; then
        rm -f "$script"
        return 1
    fi
    rm -f "$script"

    service_enable_start docker || log_warn "Could not start Docker via systemd."
    return 0
}

# Full Docker readiness gate used by install and every update path.
ensure_docker() {
    if ! docker_binary_ok; then
        if docker_is_windows_shim; then
            log_warn "The 'docker' on PATH is a Windows executable ($(command -v docker))."
            log_warn "It cannot drive containers from inside this distro."
            log_warn "Either enable WSL integration for this distro in Docker Desktop,"
            log_warn "or let this installer install Docker natively here."
        else
            log_info "Docker is not installed."
        fi
        if ! confirm "Install Docker now?" y; then
            log_error "Docker is required. Aborting."
            return 1
        fi
        install_docker || return 1
        # A freshly installed Linux client must win over any Windows shim.
        hash -r 2>/dev/null || true
    fi

    if ! docker_binary_ok; then
        log_error "Docker installation completed but the 'docker' command is still unavailable."
        return 1
    fi
    log_ok "Docker installed ($(docker --version 2>/dev/null | head -n1))"

    if ! docker_daemon_ok; then
        log_info "Docker daemon is not responding; attempting to start it..."
        service_enable_start docker || true
        # Give the daemon a moment to come up before declaring failure.
        if ! wait_for 30 2 docker info; then
            log_error "Docker is installed but the daemon is not running."
            log_error "Start it with:  sudo systemctl start docker"
            log_error "Then re-run the installer."
            return 1
        fi
    fi
    log_ok "Docker daemon running"

    if ! detect_compose; then
        log_info "Docker Compose v2 not found; installing the plugin..."
        case "$OS_FAMILY" in
            debian) pkg_install docker-compose-plugin || true ;;
            rhel)   pkg_install docker-compose-plugin || true ;;
        esac
        if ! detect_compose; then
            log_error "Docker Compose is not available."
            log_error "Install the 'docker-compose-plugin' package and re-run the installer."
            return 1
        fi
    fi
    log_ok "Docker Compose available (${DOCKER_COMPOSE_CMD[*]})"

    # A real end-to-end sanity check: the daemon must actually be able to run a
    # container, not merely answer the info endpoint.
    if ! run_logged "Docker sanity check" docker run --rm hello-world; then
        log_warn "Could not run the hello-world test container."
        log_warn "This usually means no network access to the registry, or a storage-driver problem."
        if ! confirm "Continue anyway?" n; then
            return 1
        fi
    else
        log_ok "Docker can run containers"
    fi

    return 0
}

# Convenience wrapper so callers never have to expand the array themselves.
compose() {
    if (( ${#DOCKER_COMPOSE_CMD[@]} == 0 )); then
        detect_compose || { log_error "Docker Compose unavailable."; return 1; }
    fi
    "${DOCKER_COMPOSE_CMD[@]}" "$@"
}
