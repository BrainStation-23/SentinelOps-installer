#!/usr/bin/env bash
# lib/repo.sh - deployment key handling and the Sentinel Ops Git checkout.
# shellcheck shell=bash

SO_KNOWN_HOSTS=""

# ---------------------------------------------------------------------------
# Deployment key
# ---------------------------------------------------------------------------

# Find the deployment key. Searched in order: the configured path, the
# installation root, and the directory the installer was launched from.
deploy_key_locate() {
    local candidates=() c
    [[ -n "$DEPLOY_KEY" ]] && candidates+=("$DEPLOY_KEY")
    candidates+=(
        "${INSTALL_DIR}/deploy_key"
        "${CONFIG_DIR}/deploy_key"
        "${SO_SOURCE_DIR}/deploy_key"
        "$(pwd)/deploy_key"
    )
    for c in "${candidates[@]}"; do
        [[ -n "$c" && -f "$c" ]] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

# Validate the key and lock down its permissions. OpenSSH refuses to use a key
# that is group- or world-readable.
deploy_key_prepare() {
    local key
    if ! key="$(deploy_key_locate)"; then
        log_error "No deployment key found."
        printf '\n'
        printf 'The Sentinel Ops repository is private and needs an SSH deployment key.\n'
        printf 'Place the private key at one of:\n'
        printf '  %s/deploy_key\n' "$INSTALL_DIR"
        printf '  ./deploy_key   (next to the installer)\n\n'
        return 1
    fi

    if [[ ! -r "$key" ]]; then
        log_error "Deployment key is not readable: ${key}"
        return 1
    fi

    # Copy into the installation so later updates do not depend on wherever the
    # operator originally left it.
    local dest="${CONFIG_DIR}/deploy_key"
    if [[ "$key" != "$dest" ]]; then
        mkdir -p "$CONFIG_DIR"
        cp "$key" "$dest"
        key="$dest"
    fi
    chmod 600 "$key" || { log_error "Could not chmod 600 ${key}"; return 1; }

    if ! grep -qE 'BEGIN .*PRIVATE KEY' "$key"; then
        log_error "${key} does not look like an SSH private key."
        log_error "Make sure you copied the private key, not the .pub file."
        return 1
    fi

    # A key that travelled through Windows carries CRLF line endings, and
    # OpenSSH rejects it with "error in libcrypto" - which reads like a corrupt
    # or wrong key rather than a line-ending problem, and sends operators off
    # regenerating perfectly good deploy keys. Normalise instead.
    if grep -qU $'\r' "$key" 2>/dev/null; then
        log_info "Deployment key had Windows line endings; normalising to LF."
        local tmp
        tmp="$(mktemp)"
        tr -d '\r' <"$key" >"$tmp" && cat "$tmp" >"$key"
        rm -f "$tmp"
        chmod 600 "$key"
    fi

    DEPLOY_KEY="$key"
    log_ok "Deployment key ready (${key})"
    return 0
}

# Host of an SSH-style Git URL; empty for HTTPS remotes.
_repo_ssh_host() {
    local url="$1"
    case "$url" in
        ssh://*)  url="${url#ssh://}"; url="${url#*@}"; url="${url%%/*}"; printf '%s' "${url%%:*}" ;;
        *@*:*)    url="${url#*@}";     printf '%s' "${url%%:*}" ;;
        *)        return 1 ;;
    esac
}

# Pin the remote's host key so clones never block on an interactive prompt and
# are not silently vulnerable to a substituted host.
# Keep only genuine host-key entries: "<host> <keytype> <base64>".
#
# Filtering on "not a comment" is not enough: an ssh-keyscan that cannot
# negotiate with the server prints diagnostics that are neither comments nor
# keys, and it can still exit 0. Writing those into known_hosts produces a file
# that parses but holds no usable key, which surfaces much later as an
# unexplained "Host key verification failed".
_host_key_lines() {
    local host="$1"
    grep -E '^[^#[:space:]]+[[:space:]]+(ssh-ed25519|ssh-rsa|ssh-dss|ecdsa-sha2-[^[:space:]]+|sk-ssh-[^[:space:]]+|sk-ecdsa-[^[:space:]]+)[[:space:]]+[A-Za-z0-9+/=]+' \
        | grep -F "$host" || true
}

deploy_key_known_hosts() {
    local host scanned
    host="$(_repo_ssh_host "$APP_REPOSITORY")" || return 0
    SO_KNOWN_HOSTS="${CONFIG_DIR}/known_hosts"
    mkdir -p "$CONFIG_DIR"

    # Only trust an existing file if it holds a real key line for this host.
    if [[ -s "$SO_KNOWN_HOSTS" ]] && \
       [[ -n "$(_host_key_lines "$host" <"$SO_KNOWN_HOSTS")" ]]; then
        chmod 644 "$SO_KNOWN_HOSTS" 2>/dev/null || true
        return 0
    fi

    log_info "Recording the host key for ${host}..."
    scanned="$(ssh-keyscan -T 10 "$host" 2>/dev/null | _host_key_lines "$host")"

    if [[ -z "$scanned" ]]; then
        # Better to let SSH learn the key on first contact than to write a file
        # that makes strict checking fail against every host.
        log_warn "ssh-keyscan could not retrieve a host key for ${host}; falling back to accept-new."
        SO_KNOWN_HOSTS=""
        return 0
    fi

    printf '%s\n' "$scanned" >"$SO_KNOWN_HOSTS"
    chmod 644 "$SO_KNOWN_HOSTS" 2>/dev/null || true
    log_ok "Pinned $(printf '%s\n' "$scanned" | wc -l | tr -d ' ') host key(s) for ${host}"
    return 0
}

# The SSH command used for every Git operation. IdentitiesOnly stops SSH from
# offering any other agent key and tripping the server's auth-attempt limit.
git_ssh_command() {
    local cmd="ssh -i ${DEPLOY_KEY} -o IdentitiesOnly=yes -o BatchMode=yes"
    if [[ -n "$SO_KNOWN_HOSTS" ]]; then
        cmd+=" -o UserKnownHostsFile=${SO_KNOWN_HOSTS} -o StrictHostKeyChecking=yes"
    else
        cmd+=" -o StrictHostKeyChecking=accept-new"
    fi
    printf '%s' "$cmd"
}

# Cheap reachability probe before committing to a full clone.
repo_test_access() {
    log_info "Verifying access to ${APP_REPOSITORY}..."
    if GIT_SSH_COMMAND="$(git_ssh_command)" GIT_TERMINAL_PROMPT=0 \
        git ls-remote --heads "$APP_REPOSITORY" >>"${SO_LOG_FILE:-/dev/null}" 2>&1; then
        log_ok "Repository accessible"
        return 0
    fi
    log_error "Cannot access ${APP_REPOSITORY} with the supplied deployment key."
    printf '\n'
    printf 'Check that:\n'
    printf '  - the key is registered as a deploy key on the repository\n'
    printf '  - the repository URL is correct\n'
    printf '  - this host can reach the Git server\n\n'
    return 1
}

# Confirm the branch exists before cloning, so the failure message is useful.
repo_branch_exists() {
    GIT_SSH_COMMAND="$(git_ssh_command)" GIT_TERMINAL_PROMPT=0 \
        git ls-remote --heads "$APP_REPOSITORY" "$APP_BRANCH" 2>/dev/null | grep -q .
}

# ---------------------------------------------------------------------------
# Checkout
# ---------------------------------------------------------------------------

repo_is_cloned() {
    [[ -d "${APP_DIR}/.git" ]]
}

app_git() {
    GIT_SSH_COMMAND="$(git_ssh_command)" GIT_TERMINAL_PROMPT=0 \
        git -C "$APP_DIR" "$@"
}

repo_clone() {
    if repo_is_cloned; then
        log_ok "Repository already cloned at ${APP_DIR}"
        return 0
    fi
    if [[ -d "$APP_DIR" ]] && [[ -n "$(ls -A "$APP_DIR" 2>/dev/null)" ]]; then
        log_error "${APP_DIR} exists and is not a Git checkout."
        log_error "Move it aside and re-run, or choose a different installation directory."
        return 1
    fi

    if ! repo_branch_exists; then
        log_error "Branch '${APP_BRANCH}' does not exist on ${APP_REPOSITORY}."
        return 1
    fi

    log_info "Cloning ${APP_REPOSITORY} (branch ${APP_BRANCH})..."
    if ! run_logged "git clone" env \
            GIT_SSH_COMMAND="$(git_ssh_command)" GIT_TERMINAL_PROMPT=0 \
            git clone --branch "$APP_BRANCH" "$APP_REPOSITORY" "$APP_DIR"; then
        return 1
    fi
    log_ok "Repository cloned"
    return 0
}

# Validate the checkout has the layout the installer depends on.
repo_validate() {
    local missing=()
    [[ -f "${APP_DIR}/package.json" ]]          || missing+=("package.json")
    [[ -d "${APP_DIR}/supabase/migrations" ]]   || missing+=("supabase/migrations/")
    [[ -d "${APP_DIR}/supabase/functions" ]]    || missing+=("supabase/functions/")

    if (( ${#missing[@]} )); then
        log_error "Invalid Sentinel Ops repository."
        printf '\nExpected:\n'
        printf '  package.json\n  supabase/migrations/\n  supabase/functions/\n'
        printf '\nMissing:\n'
        printf '  %s\n' "${missing[@]}"
        printf '\n'
        return 1
    fi
    log_ok "Repository layout validated"
    return 0
}

repo_commit()       { app_git rev-parse HEAD 2>/dev/null || printf 'unknown'; }
repo_short_commit() { app_git rev-parse --short HEAD 2>/dev/null || printf 'unknown'; }

# Fetch and fast-forward. A non-fast-forward is reported rather than forced:
# local divergence means someone edited the checkout, and silently discarding
# that is worse than stopping.
repo_update() {
    repo_is_cloned || { log_error "No repository at ${APP_DIR}"; return 1; }

    local before after
    before="$(repo_commit)"

    log_info "Fetching latest changes..."
    if ! run_logged "git fetch" env \
            GIT_SSH_COMMAND="$(git_ssh_command)" GIT_TERMINAL_PROMPT=0 \
            git -C "$APP_DIR" fetch --prune origin; then
        return 1
    fi

    # Make sure we are on the configured branch.
    local current
    current="$(app_git rev-parse --abbrev-ref HEAD 2>/dev/null || printf '')"
    if [[ "$current" != "$APP_BRANCH" ]]; then
        log_info "Switching from '${current}' to '${APP_BRANCH}'..."
        if ! run_logged "git checkout" env \
                GIT_SSH_COMMAND="$(git_ssh_command)" GIT_TERMINAL_PROMPT=0 \
                git -C "$APP_DIR" checkout "$APP_BRANCH"; then
            return 1
        fi
    fi

    if ! app_git merge --ff-only "origin/${APP_BRANCH}" >>"${SO_LOG_FILE:-/dev/null}" 2>&1; then
        log_error "Cannot fast-forward ${APP_DIR} to origin/${APP_BRANCH}."
        log_error "The local checkout has diverged or has uncommitted changes."
        log_error "Inspect it with:  git -C ${APP_DIR} status"
        return 1
    fi

    after="$(repo_commit)"
    if [[ "$before" == "$after" ]]; then
        log_ok "Already up to date ($(repo_short_commit))"
    else
        log_ok "Updated ${before:0:7} -> ${after:0:7}"
        app_git log --oneline "${before}..${after}" 2>/dev/null | head -n 20 || true
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Configuration prompts
# ---------------------------------------------------------------------------

repo_prompt_config() {
    section "Sentinel Ops Repository"
    prompt_default APP_REPOSITORY "Repository" "$APP_REPOSITORY"
    prompt_default APP_BRANCH     "Branch"     "$APP_BRANCH"
}
