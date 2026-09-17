#!/usr/bin/env bash
# lib/firewall.sh - open/close host firewall ports for ufw or firewalld.
#
# The installer never enables or configures a firewall itself - see the
# README's own guidance to run `ufw enable` before installing. This module
# only pokes a hole for a specific port in whichever manager is already
# present, and only when the operator explicitly asks for public exposure
# (see lib/commands/network.sh). If no supported manager is found, or the one
# found is installed but inactive, every function here warns and returns
# success rather than failing the caller: the absence of a firewall manager
# is the operator's choice, not this installer's to override.
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
