#!/usr/bin/env bash
# lib/firewall.sh - open/close host firewall ports for ufw or firewalld.
#
# This module pokes a hole for a specific port in whichever manager is
# already active (see lib/commands/network.sh), and, on a fresh install,
# offers to bring an installed-but-inactive ufw up to a safe default-deny
# baseline (see firewall_ensure_active() below) - stock Ubuntu/Debian ship ufw
# installed but not enabled, so a fresh host is otherwise wide open on every
# port until an operator remembers to do this by hand. If no supported
# manager is found, every function here warns and returns success rather than
# failing the caller: the absence of a firewall manager entirely is the
# operator's choice, not this installer's to override.
# shellcheck shell=bash

# Set by firewall_detect(): ufw | firewalld | none
FIREWALL_BACKEND=""

firewall_detect() {
    if have_cmd ufw; then
        FIREWALL_BACKEND="ufw"
    elif have_cmd firewall-cmd; then
        FIREWALL_BACKEND="firewalld"
    else
        FIREWALL_BACKEND="none"
    fi
    printf '%s' "$FIREWALL_BACKEND"
}

# True when the detected backend is actually enforcing rules right now. A
# manager that is installed but inactive is not blocking anything, so opening
# a port in it would not change what is reachable - worth saying so rather
# than silently reporting "done".
firewall_active() {
    case "$FIREWALL_BACKEND" in
        ufw)       ufw status 2>/dev/null | grep -q '^Status: active' ;;
        firewalld) have_cmd systemctl && systemctl is-active --quiet firewalld 2>/dev/null ;;
        *)         return 1 ;;
    esac
}

# firewall_open_port <port> [proto=tcp]
firewall_open_port() {
    local port="$1" proto="${2:-tcp}"
    firewall_detect >/dev/null

    case "$FIREWALL_BACKEND" in
        none)
            log_warn "No supported firewall manager (ufw/firewalld) found."
            log_warn "Port ${port}/${proto} was not opened automatically; open it with whatever this host uses."
            return 0
            ;;
    esac

    if ! firewall_active; then
        log_warn "${FIREWALL_BACKEND} is installed but not active; port ${port}/${proto} was not explicitly opened."
        log_warn "It is also not blocked - an inactive firewall filters nothing."
        return 0
    fi

    case "$FIREWALL_BACKEND" in
        ufw)
            run_logged "ufw allow ${port}/${proto}" ufw allow "${port}/${proto}" || return 1
            ;;
        firewalld)
            run_logged "firewall-cmd add-port ${port}/${proto}" \
                firewall-cmd --permanent --add-port="${port}/${proto}" || return 1
            run_logged "firewall-cmd reload" firewall-cmd --reload || return 1
            ;;
    esac
    log_ok "Opened ${port}/${proto} in ${FIREWALL_BACKEND}"
    return 0
}

# firewall_close_port <port> [proto=tcp] - best effort, never fatal. Removing a
# rule that was never added is not an error worth stopping anything for.
firewall_close_port() {
    local port="$1" proto="${2:-tcp}"
    firewall_detect >/dev/null
    firewall_active || return 0

    case "$FIREWALL_BACKEND" in
        ufw)
            run_logged "ufw delete allow ${port}/${proto}" ufw delete allow "${port}/${proto}" || true
            ;;
        firewalld)
            run_logged "firewall-cmd remove-port ${port}/${proto}" \
                firewall-cmd --permanent --remove-port="${port}/${proto}" || true
            run_logged "firewall-cmd reload" firewall-cmd --reload || true
            ;;
    esac
    log_ok "Closed ${port}/${proto} in ${FIREWALL_BACKEND}"
    return 0
}

# ---------------------------------------------------------------------------
# Bringing an inactive firewall up
# ---------------------------------------------------------------------------

# Every port sshd actually listens on, per /etc/ssh/sshd_config, so enabling
# ufw never locks out the session running the install over a non-default SSH
# port. Falls back to 22 (sshd's own default) when the file is unreadable or
# names no port explicitly.
firewall_ssh_ports() {
    local ports
    ports="$(grep -riE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config 2>/dev/null \
                | grep -oE '[0-9]+')"
    printf '%s' "${ports:-22}"
}

# On a host where nothing is enforcing anything yet, offer to turn ufw on
# with a safe minimal baseline: SSH (so the current session survives it),
# Supabase's gateway (always publicly bound - upstream's own choice, so it was
# already reachable before this ran) and the frontend port if it is
# publicly bound. Never touches a firewall that is already active, and never
# touches firewalld - RHEL-family distributions ship it enabled by default,
# so one that is inactive there reflects a deliberate choice, not an oversight.
firewall_ensure_active() {
    firewall_detect >/dev/null
    if firewall_active; then
        log_ok "${FIREWALL_BACKEND} already active"
        return 0
    fi

    case "$FIREWALL_BACKEND" in
        none)
            log_warn "No firewall manager (ufw/firewalld) found on this host."
            log_warn "Nothing is filtering inbound traffic - configure one manually."
            return 0
            ;;
        firewalld)
            log_warn "firewalld is installed but inactive; leaving it as-is."
            log_warn "Enable it yourself (systemctl enable --now firewalld) if you want it enforcing."
            return 0
            ;;
    esac

    log_warn "ufw is installed but not active - this host has no firewall enforcing anything."
    local ssh_ports port allow_desc
    ssh_ports="$(firewall_ssh_ports)"
    allow_desc="SSH (${ssh_ports// /, }), Supabase gateway ($(supabase_kong_port 2>/dev/null || printf 8000))"
    [[ "${APP_BIND:-}" == "0.0.0.0" ]] && allow_desc="${allow_desc}, frontend (${APP_PORT})"

    if ! confirm "Enable ufw now with a safe default (deny incoming except ${allow_desc})?" y; then
        log_warn "Leaving ufw inactive. Configure a firewall yourself - see the README's Firewall section."
        return 0
    fi

    for port in $ssh_ports; do
        run_logged "ufw allow ${port}/tcp" ufw allow "${port}/tcp" || {
            log_error "Could not allow SSH (${port}/tcp) before enabling ufw; refusing to proceed."
            return 1
        }
    done
    run_logged "ufw allow $(supabase_kong_port 2>/dev/null || printf 8000)/tcp" \
        ufw allow "$(supabase_kong_port 2>/dev/null || printf 8000)/tcp" || true
    if [[ "${APP_BIND:-}" == "0.0.0.0" ]]; then
        run_logged "ufw allow ${APP_PORT}/tcp" ufw allow "${APP_PORT}/tcp" || true
    fi
    run_logged "ufw default deny incoming"  ufw default deny incoming  || true
    run_logged "ufw default allow outgoing" ufw default allow outgoing || true

    if ! run_logged "ufw enable" ufw --force enable; then
        log_error "ufw enable failed; this host still has no firewall enforcing anything."
        return 1
    fi

    FIREWALL_BACKEND="ufw"
    log_ok "ufw enabled: ${allow_desc} allowed, everything else denied inbound"
    log_warn "Add a rule yourself for any other port you open later (e.g. 80/443 for a reverse proxy)."
    return 0
}
