#!/usr/bin/env bash
# lib/restic.sh - install restic and a generic, role-based repository
# wrapper. A "role" is "secondary" or "offsite" (see lib/commands/remote.sh);
# each role has its own repository, password file and credentials file, so
# the two 3-2-1 copies are configured and driven identically.
#
# restic itself is backend-agnostic via its repository URL (s3:, b2:, sftp:,
# a local path, ...), so nothing here special-cases a specific cloud
# provider - the operator supplies a repository URL plus whatever backend
# credentials restic's chosen backend needs.
# shellcheck shell=bash

RESTIC_BIN="${RESTIC_BIN:-restic}"
# Pinned, not floating: bump deliberately when adopting a newer release.
RESTIC_PINNED_VERSION="0.17.3"

# ---------------------------------------------------------------------------
# Pure helpers - role/path/string mapping, no restic or Docker involved
# ---------------------------------------------------------------------------

_restic_password_file() { printf '%s/restic-%s.pass' "$CONFIG_DIR" "$1"; }
_restic_credentials_file() { printf '%s/restic-%s.env' "$CONFIG_DIR" "$1"; }

# The installer.env variable name for a role's setting, e.g.
# role=secondary field=ENABLED -> RESTIC_SECONDARY_ENABLED.
_restic_config_var() {
    local role="$1" field="$2"
    printf 'RESTIC_%s_%s' "$(printf '%s' "$role" | tr '[:lower:]' '[:upper:]')" "$field"
}

# Build `restic forget`'s retention flags, omitting any --keep-* whose value
# is 0 so a role can disable a bucket entirely (e.g. daily-only retention).
_restic_forget_args() {
    local keep_daily="$1" keep_weekly="$2" keep_monthly="$3" args=()
    [[ "$keep_daily"   != "0" ]] && args+=(--keep-daily   "$keep_daily")
    [[ "$keep_weekly"  != "0" ]] && args+=(--keep-weekly  "$keep_weekly")
    [[ "$keep_monthly" != "0" ]] && args+=(--keep-monthly "$keep_monthly")
    args+=(--prune)
    printf '%s\n' "${args[@]}"
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

# Try the distro package first, then a pinned static-binary download.
# Warns and returns 1 on failure rather than dying - this runs from
# `remote configure`, which should report failure cleanly, not crash.
restic_install() {
    have_cmd restic && return 0

    log_info "Installing restic..."
    if pkg_install restic >/dev/null 2>&1 && have_cmd restic; then
        log_ok "restic installed ($(restic version 2>/dev/null | head -n1))"
        return 0
    fi

    log_info "restic is not packaged here; downloading v${RESTIC_PINNED_VERSION}..."
    local url tmp
    url="https://github.com/restic/restic/releases/download/v${RESTIC_PINNED_VERSION}/restic_${RESTIC_PINNED_VERSION}_linux_amd64.bz2"
    # bunzip2 needs a .bz2-suffixed name to decompress in place; without one it
    # writes to <name>.out instead of overwriting, silently leaving the
    # compressed original where the binary is expected next.
    tmp="$(mktemp).bz2"
    if ! curl -fsSL --max-time 60 "$url" -o "$tmp" 2>>"${SO_LOG_FILE:-/dev/null}"; then
        log_warn "Could not download restic from ${url}."
        rm -f "$tmp"
        return 1
    fi
    if ! bunzip2 -f "$tmp" 2>>"${SO_LOG_FILE:-/dev/null}"; then
        log_warn "Could not decompress the downloaded restic binary."
        rm -f "$tmp" "${tmp%.bz2}"
        return 1
    fi
    tmp="${tmp%.bz2}"
    install -m 755 "$tmp" /usr/local/bin/restic 2>/dev/null || {
        log_warn "Could not install restic to /usr/local/bin."
        rm -f "$tmp"
        return 1
    }
    rm -f "$tmp"

    have_cmd restic || { log_warn "restic install did not produce a usable binary."; return 1; }
    log_ok "restic installed ($(restic version 2>/dev/null | head -n1))"
    return 0
}

# ---------------------------------------------------------------------------
# Repository access - credentials touch the environment only inside
# _restic_run, for the duration of a single call, then are unset. Mirrors
# frontend_run_container()'s export-around-the-call pattern for
# SUPABASE_SERVICE_ROLE_KEY (lib/frontend.sh) - run_logged logs its argv, so
# nothing sensitive may arrive as NAME=value text on a command line.
# ---------------------------------------------------------------------------

_restic_run() {
    local role="$1"; shift
    local repo_var pass_file creds_file key exported=() rc=0

    repo_var="$(_restic_config_var "$role" REPOSITORY)"
    pass_file="$(_restic_password_file "$role")"
    creds_file="$(_restic_credentials_file "$role")"

    [[ -n "${!repo_var:-}" ]] || { log_error "No repository configured for role '${role}'."; return 1; }
    [[ -f "$pass_file" ]] || { log_error "No repository password for role '${role}' at ${pass_file}."; return 1; }

    export RESTIC_REPOSITORY="${!repo_var}"
    export RESTIC_PASSWORD_FILE="$pass_file"
    exported=(RESTIC_REPOSITORY RESTIC_PASSWORD_FILE)

    if [[ -f "$creds_file" ]]; then
        while IFS= read -r key; do
            [[ -n "$key" ]] || continue
            export "${key}=$(env_get "$creds_file" "$key")"
            exported+=("$key")
        done < <(env_keys "$creds_file")
    fi

    run_logged "restic ${1:-}" "$RESTIC_BIN" "$@" || rc=$?
    unset "${exported[@]}"
    return "$rc"
}

# Idempotent: an already-initialised repository is treated as success.
restic_init() {
    local role="$1" out rc=0
    out="$(_restic_run "$role" init 2>&1)" || rc=$?
    if (( rc != 0 )) && ! grep -qiE 'already (initialized|exists)' <<<"$out"; then
        printf '%s\n' "$out" >&2
        return "$rc"
    fi
    return 0
}

restic_backup() {
    local role="$1" path="$2"
    _restic_run "$role" backup "$path" --tag sentinel-ops
}

restic_snapshots() { _restic_run "$1" snapshots; }

restic_forget() {
    local role="$1" daily_var weekly_var monthly_var
    daily_var="$(_restic_config_var "$role" KEEP_DAILY)"
    weekly_var="$(_restic_config_var "$role" KEEP_WEEKLY)"
    monthly_var="$(_restic_config_var "$role" KEEP_MONTHLY)"
    # shellcheck disable=SC2046 # intentional: one flag/value per line, split on purpose
    _restic_run "$role" forget $(_restic_forget_args "${!daily_var:-7}" "${!weekly_var:-4}" "${!monthly_var:-6}")
}

restic_check() { _restic_run "$1" check; }

restic_restore() {
    local role="$1" snapshot="${2:-latest}" target="$3"
    _restic_run "$role" restore "$snapshot" --target "$target"
}
