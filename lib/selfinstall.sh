#!/usr/bin/env bash
# lib/selfinstall.sh - copy the installer into the installation root.
#
# After this runs, `sentinel-ops` is on PATH and every later update uses the
# copy under the installation directory rather than whatever checkout the
# operator happened to run first.
# shellcheck shell=bash

SO_BIN_LINK="/usr/local/bin/sentinel-ops"

selfinstall() {
    local dest_bin="${INSTALL_DIR}/bin" dest_lib="${INSTALL_DIR}/lib" dest_assets="${INSTALL_DIR}/assets"

    # Already running from the installed location: nothing to copy.
    if [[ "$SO_ROOT" == "$INSTALL_DIR" ]]; then
        log_debug "already running from ${INSTALL_DIR}"
    else
        mkdir -p "$dest_bin" "$dest_lib" "$dest_assets"
        cp -a "${SO_ROOT}/bin/." "$dest_bin/"
        cp -a "${SO_ROOT}/lib/." "$dest_lib/"
        cp -a "${SO_ROOT}/assets/." "$dest_assets/"
        chmod +x "${dest_bin}/sentinel-ops" 2>/dev/null || true
        log_ok "Installer copied to ${INSTALL_DIR}"
        # Remember the checkout this copy was taken from, so a later run can
        # notice when that checkout has moved on. Recorded only when copying:
        # running the installed copy must not overwrite its own provenance.
        state_set INSTALLED_FROM "$SO_ROOT"
    fi

    # From here on, templates come from the installed copy.
    SO_ASSETS_DIR="$dest_assets"
    SO_LIB_DIR="$dest_lib"

    # Put the command on PATH.
    if [[ -w "$(dirname "$SO_BIN_LINK")" ]]; then
        ln -sfn "${dest_bin}/sentinel-ops" "$SO_BIN_LINK"
        log_ok "Command available as: sentinel-ops"
    else
        log_warn "Could not write ${SO_BIN_LINK}."
        log_warn "Run the installed copy directly: ${dest_bin}/sentinel-ops"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Staleness
#
# `install` copies this tool into INSTALL_DIR, so the command on PATH is a
# snapshot of a checkout rather than a live view of it. Pulling in that
# checkout therefore changes nothing about what `sentinel-ops` runs, and the
# only visible symptom is a command or flag that the repository clearly has
# and the installed copy does not. Say it plainly instead.
# ---------------------------------------------------------------------------

# True when the installer files under $1 differ from those under $2.
#
# Content, not timestamps: `cp -a` preserves mtimes only as precisely as the
# destination filesystem records them, so a copy that is byte for byte correct
# can still look older by a rounding error. A guard that cries stale on a
# healthy installation is a guard that gets ignored.
_installer_differs() {
    local src="$1" dst="$2" sub
    command -v diff >/dev/null 2>&1 || return 1
    for sub in bin lib assets; do
        [[ -d "${src}/${sub}" && -d "${dst}/${sub}" ]] || continue
        diff -qr "${src}/${sub}" "${dst}/${sub}" >/dev/null 2>&1 || return 0
    done
    return 1
}

warn_if_stale() {
    # Only the installed copy can be behind something. A checkout being run
    # directly is by definition the version the operator picked.
    [[ "$SO_ROOT" == "$INSTALL_DIR" ]] || return 0

    local src
    src="$(state_get INSTALLED_FROM '')"
    [[ -n "$src" && -d "$src" ]] || return 0
    _installer_differs "$src" "$SO_ROOT" || return 0

    log_warn "${src} differs from the installed copy in ${INSTALL_DIR}."
    log_warn "This command is a copy and does not update itself. To refresh it:"
    log_warn "  sudo ${src}/install.sh"
    return 0
}
