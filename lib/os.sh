#!/usr/bin/env bash
# lib/os.sh - Linux / distribution detection.
# shellcheck shell=bash

# Populated by detect_os():
OS_ID=""            # ubuntu, debian, rhel, centos, fedora, rocky, almalinux
OS_ID_LIKE=""       # debian / rhel fedora ...
OS_NAME=""          # pretty name, e.g. "Ubuntu 24.04 LTS"
OS_VERSION=""       # version id, e.g. "24.04"
OS_FAMILY=""        # debian | rhel
PKG_MANAGER=""      # apt-get | dnf | yum

# The distributions the installer claims to support.
readonly SUPPORTED_DEBIAN="debian ubuntu"
readonly SUPPORTED_RHEL="rhel centos fedora rocky almalinux"

require_linux() {
    local kernel
    kernel="$(uname -s)"
    if [[ "$kernel" != "Linux" ]]; then
        log_error "The Sentinel Ops installer targets Linux servers (detected: ${kernel})."
        log_error "Run it on a supported distribution - see the README."
        exit 1
    fi
    log_ok "Linux detected"
}

# Parse /etc/os-release and classify the distribution.
# Returns non-zero rather than exiting, so read-only commands such as `status`
# still work on a host this installer does not support.
detect_os() {
    if [[ ! -r /etc/os-release ]]; then
        OS_NAME="unknown (no /etc/os-release)"
        return 1
    fi

    # Read the file line by line rather than sourcing it, so that a malformed
    # os-release cannot execute anything.
    OS_ID="$(env_get /etc/os-release ID || true)"
    OS_ID_LIKE="$(env_get /etc/os-release ID_LIKE || true)"
    OS_NAME="$(env_get /etc/os-release PRETTY_NAME || true)"
    OS_VERSION="$(env_get /etc/os-release VERSION_ID || true)"
    OS_ID="$(printf '%s' "$OS_ID" | tr '[:upper:]' '[:lower:]')"
    OS_ID_LIKE="$(printf '%s' "$OS_ID_LIKE" | tr '[:upper:]' '[:lower:]')"
    [[ -n "$OS_NAME" ]] || OS_NAME="${OS_ID} ${OS_VERSION}"

    # Classify by ID first, then fall back to ID_LIKE so that derivatives
    # (Linux Mint, Rocky, Oracle Linux) are handled without an explicit entry.
    if [[ " $SUPPORTED_DEBIAN " == *" $OS_ID "* ]]; then
        OS_FAMILY="debian"
    elif [[ " $SUPPORTED_RHEL " == *" $OS_ID "* ]]; then
        OS_FAMILY="rhel"
    elif [[ "$OS_ID_LIKE" == *debian* ]]; then
        OS_FAMILY="debian"
    elif [[ "$OS_ID_LIKE" == *rhel* || "$OS_ID_LIKE" == *fedora* ]]; then
        OS_FAMILY="rhel"
    else
        OS_FAMILY=""
    fi

    case "$OS_FAMILY" in
        debian) PKG_MANAGER="apt-get" ;;
        rhel)
            if have_cmd dnf; then PKG_MANAGER="dnf"
            elif have_cmd yum; then PKG_MANAGER="yum"
            else PKG_MANAGER=""; fi
            ;;
    esac
}

# Abort with an explicit, actionable message on an unsupported distribution.
require_supported_os() {
    if ! detect_os; then
        log_error "Cannot read /etc/os-release - unable to identify this distribution."
        exit 1
    fi
    if [[ -z "$OS_FAMILY" || -z "$PKG_MANAGER" ]]; then
        log_error "Unsupported operating system: ${OS_NAME:-unknown}"
        printf '\n'
        printf 'Sentinel Ops Installer currently supports:\n'
        printf '  Ubuntu / Debian\n'
        printf '  RHEL / CentOS / Fedora (and Rocky / AlmaLinux)\n\n'
        exit 1
    fi
    log_ok "${OS_NAME} detected"
    log_debug "family=${OS_FAMILY} pkg=${PKG_MANAGER} id=${OS_ID} version=${OS_VERSION}"
}

# Refresh the package index at most once per run.
_PKG_INDEX_UPDATED="false"
pkg_update_index() {
    [[ "$_PKG_INDEX_UPDATED" == "true" ]] && return 0
    case "$PKG_MANAGER" in
        apt-get) run_logged "apt-get update" env DEBIAN_FRONTEND=noninteractive apt-get update -qq || return 1 ;;
        dnf|yum) run_logged "${PKG_MANAGER} makecache" "$PKG_MANAGER" -q makecache || true ;;
    esac
    _PKG_INDEX_UPDATED="true"
    return 0
}

pkg_install() {
    local pkgs=("$@")
    (( ${#pkgs[@]} )) || return 0
    pkg_update_index || return 1
    case "$PKG_MANAGER" in
        apt-get)
            run_logged "apt-get install ${pkgs[*]}" \
                env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}"
            ;;
        dnf|yum)
            run_logged "${PKG_MANAGER} install ${pkgs[*]}" \
                "$PKG_MANAGER" install -y -q "${pkgs[@]}"
            ;;
        *)
            log_error "No usable package manager for this system."
            return 1
            ;;
    esac
}

# systemd is not guaranteed (containers, WSL). Callers must tolerate failure.
service_enable_start() {
    local svc="$1"
    if ! have_cmd systemctl; then
        log_warn "systemctl not available; cannot manage the ${svc} service automatically."
        return 1
    fi
    systemctl enable "$svc" >/dev/null 2>&1 || true
    systemctl start "$svc" >/dev/null 2>&1 || return 1
    return 0
}
