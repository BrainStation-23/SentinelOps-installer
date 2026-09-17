#!/usr/bin/env bash
# lib/supabase.sh - self-hosted Supabase deployment, configuration and health.
# shellcheck shell=bash

SUPABASE_SETUP_URL="https://supabase.link/setup.sh"
SUPABASE_REPO_URL="https://github.com/supabase/supabase.git"

# Files and directories that carry *state* and must survive an update.
# Everything else in the Supabase directory is deployment scaffolding and is
# refreshed from upstream.
SUPABASE_PRESERVE=(
    ".env"
    "volumes/db/data"
    "volumes/storage"
    "volumes/functions"
)

# ---------------------------------------------------------------------------
# Compose helpers
# ---------------------------------------------------------------------------

# Run docker compose against the Supabase deployment.
#
# No -f is passed on purpose. Supabase's run.sh enables optional overlays (such
# as the logs/analytics stack) by setting COMPOSE_FILE in supabase/.env, and
# Compose reads that itself. Hardcoding -f docker-compose.yml would silently
# drop every overlay service from ps, logs, up and down.
supabase_compose() {
    ( cd "$SUPABASE_DIR" && compose --env-file "${SUPABASE_DIR}/.env" "$@" )
}

# The same invocation as a single string, for run_logged's bash -c form.
_supabase_compose_cmd() {
    printf "cd '%s' && %s --env-file '%s/.env'" \
        "$SUPABASE_DIR" "${DOCKER_COMPOSE_CMD[*]}" "$SUPABASE_DIR"
}

# Resolve the container id backing a compose service ("" when not running).
supabase_container_id() {
    supabase_compose ps -q "$1" 2>/dev/null | head -n1
}

supabase_service_running() {
    local cid
    cid="$(supabase_container_id "$1")"
    [[ -n "$cid" ]] && [[ "$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null)" == "true" ]]
}

# Docker health status of a service: healthy | unhealthy | starting | none.
supabase_service_health() {
    local cid status
    cid="$(supabase_container_id "$1")"
    [[ -n "$cid" ]] || { printf 'missing'; return 1; }
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null)"
    printf '%s' "${status:-none}"
}

supabase_kong_port() {
    local p
    p="$(env_get "${SUPABASE_DIR}/.env" KONG_HTTP_PORT 2>/dev/null || true)"
    printf '%s' "${p:-8000}"
}

supabase_installed() {
    [[ -f "${SUPABASE_DIR}/docker-compose.yml" && -f "${SUPABASE_DIR}/.env" ]]
}

# The Docker network the Supabase stack runs on. The frontend attaches to it so
# it can reach Supabase by service name instead of going back out through the
# host.
supabase_network_name() {
    local cid net
    cid="$(supabase_container_id "$(supabase_db_service)")"
    if [[ -n "$cid" ]]; then
        net="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' "$cid" 2>/dev/null | head -n1)"
        [[ -n "$net" ]] && { printf '%s' "$net"; return 0; }
    fi
    # Fall back to Compose's default naming: <project>_default, where the
    # project defaults to the sanitised directory name.
    local project
    project="$(basename "$SUPABASE_DIR" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]_-')"
    printf '%s_default' "$project"
}

supabase_current_version() {
    local v=""
    [[ -f "${SUPABASE_DIR}/.supabase-version" ]] && v="$(tr -d '[:space:]' <"${SUPABASE_DIR}/.supabase-version")"
    [[ -z "$v" ]] && v="$(state_get SUPABASE_VERSION '')"
    printf '%s' "${v:-unknown}"
}

# ---------------------------------------------------------------------------
# Fetching the upstream deployment
# ---------------------------------------------------------------------------

# Copy a directory tree while excluding stateful paths. tar is used instead of
# rsync because rsync is not installed by default on minimal RHEL images.
_sync_tree() {
    local src="$1" dst="$2"; shift 2
    local excludes=("$@") args=() e
    for e in "${excludes[@]}"; do
        args+=("--exclude=./${e}")
    done
    mkdir -p "$dst"
    ( cd "$src" && tar -cf - "${args[@]}" . ) | ( cd "$dst" && tar -xf - )
}

# Download the official Supabase deployment into a staging directory.
# Prints the staged directory path on stdout.
_supabase_stage_upstream() {
    local staging="$1" candidate=""

    # Preferred path: the official setup script. It owns prerequisite checks,
    # secret generation, JWT signing keys and the .supabase-version marker, and
    # we deliberately do not reimplement any of that.
    local script="${staging}/setup.sh"
    if curl -fsSL --max-time 60 "$SUPABASE_SETUP_URL" -o "$script" 2>/dev/null; then
        log_info "Running the official Supabase setup script..." >&2
        ( cd "$staging" && sh "$script" </dev/null ) >>"${SO_LOG_FILE:-/dev/null}" 2>&1 || \
            log_warn "Supabase setup script exited non-zero; checking what it produced." >&2
        candidate="$(find "$staging" -maxdepth 3 -name docker-compose.yml -not -path '*/node_modules/*' 2>/dev/null | head -n1)"
    else
        log_warn "Could not download ${SUPABASE_SETUP_URL}." >&2
    fi

    # Fallback: take docker/ straight from the Supabase repository. This keeps
    # a fresh install possible when supabase.link is unreachable.
    if [[ -z "$candidate" ]]; then
        log_info "Falling back to the Supabase repository (docker/ directory)..." >&2
        local repo="${staging}/_repo"
        if ! git clone --depth 1 --filter=blob:none --sparse "$SUPABASE_REPO_URL" "$repo" \
                >>"${SO_LOG_FILE:-/dev/null}" 2>&1; then
            log_error "Could not clone ${SUPABASE_REPO_URL}." >&2
            return 1
        fi
        ( cd "$repo" && git sparse-checkout set docker ) >>"${SO_LOG_FILE:-/dev/null}" 2>&1 || return 1
        candidate="${repo}/docker/docker-compose.yml"
        # Record the upstream commit so `status` can still report something.
        ( cd "$repo" && git rev-parse --short HEAD ) >"${staging}/_version" 2>/dev/null || true
        [[ -f "$candidate" ]] || { log_error "Supabase repository layout unexpected." >&2; return 1; }
    fi

    printf '%s' "$(dirname "$candidate")"
}

# Fresh install of the Supabase deployment files.
supabase_install_files() {
    if supabase_installed; then
        log_ok "Supabase deployment files already present; preserving them."
        return 0
    fi

    local staging staged
    staging="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$staging'" RETURN

    staged="$(_supabase_stage_upstream "$staging")" || return 1
    log_debug "staged Supabase deployment at ${staged}"

    mkdir -p "$SUPABASE_DIR"
    _sync_tree "$staged" "$SUPABASE_DIR"

    # Seed .env from .env.example when the setup script did not create one.
    if [[ ! -f "${SUPABASE_DIR}/.env" && -f "${SUPABASE_DIR}/.env.example" ]]; then
        cp "${SUPABASE_DIR}/.env.example" "${SUPABASE_DIR}/.env"
        log_info "Seeded supabase/.env from .env.example"
    fi
    [[ -f "${SUPABASE_DIR}/.env" ]] || { log_error "Supabase .env was not created."; return 1; }
    chmod 600 "${SUPABASE_DIR}/.env" 2>/dev/null || true

    # Record the version if the fallback path captured one.
    if [[ -s "${staging}/_version" && ! -f "${SUPABASE_DIR}/.supabase-version" ]]; then
        cp "${staging}/_version" "${SUPABASE_DIR}/.supabase-version"
    fi

    log_ok "Supabase deployment files installed at ${SUPABASE_DIR}"
    return 0
}

# ---------------------------------------------------------------------------
# Secrets
#
# The setup script normally generates these. When the fallback path was used we
# generate them here, once, and never again: regenerating JWT secrets on an
# existing installation invalidates every issued token and locks users out.
# ---------------------------------------------------------------------------

_b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# Sign an HS256 JWT. _sign_jwt <secret> <role> <issued-at> <expiry>
_sign_jwt() {
    local secret="$1" role="$2" iat="$3" exp="$4" header payload signature
    header="$(printf '{"alg":"HS256","typ":"JWT"}' | _b64url)"
    payload="$(printf '{"role":"%s","iss":"supabase","iat":%s,"exp":%s}' "$role" "$iat" "$exp" | _b64url)"
    signature="$(printf '%s.%s' "$header" "$payload" \
        | openssl dgst -sha256 -hmac "$secret" -binary | _b64url)"
    printf '%s.%s.%s' "$header" "$payload" "$signature"
}

# Is this token one of the demo JWTs upstream ships? They are issued by
# "supabase-demo" and signed with the published example secret, so a deployment
# that keeps them is wide open.
_jwt_is_demo() {
    local token="$1" payload
    [[ "$token" == eyJ* ]] || return 1
    payload="${token#*.}"
    payload="${payload%%.*}"
    [[ -n "$payload" ]] || return 1
    # base64url -> base64, then pad to a multiple of four.
    payload="$(printf '%s' "$payload" | tr '_-' '/+')"
    case $(( ${#payload} % 4 )) in
        2) payload="${payload}==" ;;
        3) payload="${payload}=" ;;
    esac
    printf '%s' "$payload" | openssl base64 -d -A 2>/dev/null | grep -q 'supabase-demo'
}

# Is this value still an upstream placeholder (or absent)?
#
# Matched against the values Supabase actually ships in .env.example rather than
# a generic "looks secret-ish" guess. Several of them - VAULT_ENC_KEY,
# DASHBOARD_PASSWORD and above all SECRET_KEY_BASE - carry no obvious
# placeholder marker, so a substring heuristic silently leaves upstream's
# published value in place on every install.
_is_placeholder() {
    local v="$1"
    [[ -z "$v" ]] && return 0
    case "$v" in
        *your-super-secret*|*your-tenant-id*|*replace-me*|*example*|*super-secret-jwt*) return 0 ;;
        *your-32-character*|*this_password_is_insecure*|*changeme*|*change-me*)         return 0 ;;
        # Published verbatim in upstream's .env.example. It looks like a real
        # secret, which is exactly why it has to be listed explicitly.
        'UpNVntn3cDxHJpq99YMc1T1AQgQpc8kfYTuRgBiYa15BLrx8etQoXz3gZv1/u2oq')              return 0 ;;
    esac
    _jwt_is_demo "$v" && return 0
    return 1
}

# Fill in any secret that is missing or still at its upstream placeholder.
supabase_generate_secrets() {
    local env_file="${SUPABASE_DIR}/.env"
    local changed=0 iat exp jwt_secret

    jwt_secret="$(env_get "$env_file" JWT_SECRET || true)"
    if _is_placeholder "$jwt_secret"; then
        jwt_secret="$(random_token 32)"
        env_set "$env_file" JWT_SECRET "$jwt_secret"
        changed=1
        # The API keys are signed with the JWT secret, so they must be reissued
        # whenever the secret is created.
        iat="$(date +%s)"
        exp=$(( iat + 60 * 60 * 24 * 365 * 10 ))
        env_set "$env_file" ANON_KEY "$(_sign_jwt "$jwt_secret" anon "$iat" "$exp")"
        env_set "$env_file" SERVICE_ROLE_KEY "$(_sign_jwt "$jwt_secret" service_role "$iat" "$exp")"
        log_info "Generated JWT secret and API keys"
    fi

    # A real JWT secret paired with demo API keys is still a broken deployment:
    # reissue the keys against whatever secret is now in place.
    jwt_secret="$(env_get "$env_file" JWT_SECRET || true)"
    if [[ -n "$jwt_secret" ]]; then
        local anon_key service_key
        anon_key="$(env_get "$env_file" ANON_KEY || true)"
        service_key="$(env_get "$env_file" SERVICE_ROLE_KEY || true)"
        if _is_placeholder "$anon_key" || _is_placeholder "$service_key"; then
            iat="$(date +%s)"
            exp=$(( iat + 60 * 60 * 24 * 365 * 10 ))
            env_set "$env_file" ANON_KEY "$(_sign_jwt "$jwt_secret" anon "$iat" "$exp")"
            env_set "$env_file" SERVICE_ROLE_KEY "$(_sign_jwt "$jwt_secret" service_role "$iat" "$exp")"
            changed=1
            log_info "Reissued the Supabase API keys"
        fi
    fi

    local key val
    for key in POSTGRES_PASSWORD SECRET_KEY_BASE VAULT_ENC_KEY \
               LOGFLARE_PUBLIC_ACCESS_TOKEN LOGFLARE_PRIVATE_ACCESS_TOKEN \
               POOLER_TENANT_ID DASHBOARD_PASSWORD; do
        val="$(env_get "$env_file" "$key" || true)"
        if _is_placeholder "$val"; then
            case "$key" in
                VAULT_ENC_KEY)     val="$(random_token 16)" ;;   # must be 32 chars
                POOLER_TENANT_ID)  val="sentinel-ops" ;;
                DASHBOARD_PASSWORD) val="$(random_token 12)" ;;
                *)                 val="$(random_token 32)" ;;
            esac
            env_set "$env_file" "$key" "$val"
            changed=1
            log_debug "generated ${key}"
        fi
    done

    if [[ -z "$(env_get "$env_file" DASHBOARD_USERNAME || true)" ]]; then
        env_set "$env_file" DASHBOARD_USERNAME "supabase"
    fi

    chmod 600 "$env_file" 2>/dev/null || true
    (( changed )) && log_ok "Supabase secrets generated" || log_ok "Supabase secrets already present (left untouched)"
    return 0
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Interactive prompts for the externally visible settings only. Secrets are
# never requested from the operator.
supabase_prompt_config() {
    section "Supabase Configuration"

    prompt_default SUPABASE_PUBLIC_URL "Supabase public URL" "$SUPABASE_PUBLIC_URL"
    SUPABASE_PUBLIC_URL="$(strip_trailing_slash "$SUPABASE_PUBLIC_URL")"

    prompt_default API_EXTERNAL_URL "API external URL" "$SUPABASE_PUBLIC_URL"
    API_EXTERNAL_URL="$(strip_trailing_slash "$API_EXTERNAL_URL")"

    prompt_default SITE_URL "Site URL (the Sentinel Ops application)" "$SITE_URL"
    SITE_URL="$(strip_trailing_slash "$SITE_URL")"

}

# Apply the operator's settings to supabase/.env. Only these keys are managed;
# everything else the operator or the setup script wrote is left alone.
supabase_apply_config() {
    local env_file="${SUPABASE_DIR}/.env"
    [[ -f "$env_file" ]] || { log_error "Missing ${env_file}"; return 1; }

    env_set "$env_file" SITE_URL            "$SITE_URL"
    env_set "$env_file" API_EXTERNAL_URL    "$API_EXTERNAL_URL"
    env_set "$env_file" SUPABASE_PUBLIC_URL "$SUPABASE_PUBLIC_URL"

    # Studio needs to reach the API through the same public hostname the
    # browser uses, otherwise its requests fail with a CORS/origin mismatch.
    env_set "$env_file" STUDIO_DEFAULT_ORGANIZATION "Sentinel Ops"
    env_set "$env_file" STUDIO_DEFAULT_PROJECT      "Sentinel Ops"

    # Allow the application origin back through auth redirects.
    local extra
    extra="$(env_get "$env_file" ADDITIONAL_REDIRECT_URLS || true)"
    if [[ "$extra" != *"$SITE_URL"* ]]; then
        if [[ -n "$extra" ]]; then
            env_set "$env_file" ADDITIONAL_REDIRECT_URLS "${extra},${SITE_URL}/**"
        else
            env_set "$env_file" ADDITIONAL_REDIRECT_URLS "${SITE_URL}/**"
        fi
    fi

    chmod 600 "$env_file" 2>/dev/null || true
    log_ok "Supabase configuration applied"
    return 0
}

# The client-side key handed to the React frontend. Newer Supabase releases
# renamed ANON_KEY to a publishable key, so both spellings are accepted.
supabase_publishable_key() {
    local env_file="${SUPABASE_DIR}/.env" key=""
    for k in ANON_KEY SUPABASE_PUBLISHABLE_KEY PUBLISHABLE_KEY SUPABASE_ANON_KEY; do
        key="$(env_get "$env_file" "$k" 2>/dev/null || true)"
        [[ -n "$key" ]] && { printf '%s' "$key"; return 0; }
    done
    return 1
}

supabase_service_role_key() {
    local env_file="${SUPABASE_DIR}/.env" key=""
    for k in SERVICE_ROLE_KEY SUPABASE_SECRET_KEY SECRET_KEY; do
        key="$(env_get "$env_file" "$k" 2>/dev/null || true)"
        [[ -n "$key" ]] && { printf '%s' "$key"; return 0; }
    done
    return 1
}

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

supabase_pull() {
    log_info "Pulling Supabase images (this can take several minutes)..."
    supabase_compose pull >>"${SO_LOG_FILE:-/dev/null}" 2>&1 || {
        log_warn "Some images could not be pulled; continuing with what is cached."
    }
    log_ok "Supabase images ready"
}

supabase_start() {
    log_info "Starting Supabase..."
    if ! run_logged "supabase up" bash -c \
        "$(_supabase_compose_cmd) up -d --remove-orphans"; then
        return 1
    fi
    log_ok "Supabase started"
}

supabase_stop() {
    log_info "Stopping Supabase..."
    supabase_compose down >>"${SO_LOG_FILE:-/dev/null}" 2>&1 || true
}

# Restart without removing volumes. Never use `down -v` here: that destroys the
# database.
supabase_restart() {
    supabase_compose up -d --remove-orphans >>"${SO_LOG_FILE:-/dev/null}" 2>&1
}

# The compose service name for Postgres differs between releases.
supabase_db_service() {
    local s
    for s in db database postgres; do
        if supabase_compose config --services 2>/dev/null | grep -qx "$s"; then
            printf '%s' "$s"; return 0
        fi
    done
    printf 'db'
}

# ---------------------------------------------------------------------------
# Health checks
# ---------------------------------------------------------------------------

supabase_check_postgres() {
    local cid svc user
    svc="$(supabase_db_service)"
    cid="$(supabase_container_id "$svc")"
    [[ -n "$cid" ]] || return 1
    user="$(env_get "${SUPABASE_DIR}/.env" POSTGRES_USER 2>/dev/null || true)"
    docker exec "$cid" pg_isready -U "${user:-postgres}" -q 2>/dev/null
}

_http_code() {
    curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@" 2>/dev/null || printf '000'
}

# Current Supabase releases front the stack with Envoy instead of Kong, and
# Envoy's RBAC filter rejects EVERY route without an apikey - including
# /auth/v1/health, which Kong used to serve unauthenticated. A probe that omits
# the key gets a flat 401 from a perfectly healthy stack, which is exactly how
# an otherwise successful install ends up failing its own health check.
supabase_check_api() {
    local port code key args=()
    port="$(supabase_kong_port)"
    key="$(supabase_publishable_key 2>/dev/null || true)"
    [[ -n "$key" ]] && args=(-H "apikey: ${key}")
    # Any of these proves the gateway routed to PostgREST rather than failing to
    # reach it: 200 from an open deployment, 401/403 from the gateway's own
    # authorization filter, 404 when the bare root is not a route.
    code="$(_http_code "${args[@]}" "http://localhost:${port}/rest/v1/")"
    [[ "$code" =~ ^(200|401|403|404)$ ]]
}

supabase_check_auth() {
    local port code key args=() cid
    port="$(supabase_kong_port)"
    key="$(supabase_publishable_key 2>/dev/null || true)"
    [[ -n "$key" ]] && args=(-H "apikey: ${key}")
    code="$(_http_code "${args[@]}" "http://localhost:${port}/auth/v1/health")"
    [[ "$code" == "200" ]] && return 0

    # The gateway is reachable but refused us. That says nothing about GoTrue,
    # so ask the container directly rather than reporting a false failure.
    cid="$(supabase_container_id auth)"
    [[ -n "$cid" ]] || return 1
    docker exec "$cid" wget -qO- http://127.0.0.1:9999/health >/dev/null 2>&1
}

supabase_check_studio() {
    # Studio is not always routed through Kong, so fall back to the container's
    # own health status.
    local port code health key args=()
    port="$(supabase_kong_port)"
    key="$(supabase_publishable_key 2>/dev/null || true)"
    [[ -n "$key" ]] && args=(-H "apikey: ${key}")
    code="$(_http_code "${args[@]}" "http://localhost:${port}/")"
    [[ "$code" =~ ^(200|301|302|401|403)$ ]] && return 0
    health="$(supabase_service_health studio 2>/dev/null || true)"
    [[ "$health" == "healthy" || "$health" == "none" ]] && supabase_service_running studio
}

# Wait for the whole stack, reporting each component as it comes up.
# Returns non-zero if any critical component fails.
supabase_health_check() {
    local timeout="${1:-180}" failed=0

    log_info "Waiting for Supabase services (up to ${timeout}s)..."

    if wait_for "$timeout" 5 supabase_check_postgres; then
        log_ok "PostgreSQL available"
    else
        log_error "PostgreSQL failed health check"
        failed=1
    fi

    if wait_for 60 5 supabase_check_api; then
        log_ok "Supabase API available"
    else
        log_error "Supabase API failed health check"
        failed=1
    fi

    if wait_for 60 5 supabase_check_auth; then
        log_ok "Auth available"
    else
        log_error "Auth failed health check"
        failed=1
    fi

    if wait_for 60 5 supabase_check_studio; then
        log_ok "Studio available"
    else
        # Studio is an operator convenience, not a runtime dependency of the
        # application, so a failure here is a warning rather than fatal.
        log_warn "Studio did not become available"
    fi

    return "$failed"
}

# ---------------------------------------------------------------------------
# Update
# ---------------------------------------------------------------------------

# Refresh the deployment scaffolding from upstream while preserving .env,
# database volumes, storage and the application's edge functions.
supabase_update_files() {
    local staging staged backup_env
    staging="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$staging'" RETURN

    staged="$(_supabase_stage_upstream "$staging")" || return 1

    # Belt and braces: keep a copy of .env outside the tree being rewritten.
    backup_env="${staging}/.env.preserved"
    cp "${SUPABASE_DIR}/.env" "$backup_env"

    log_info "Refreshing Supabase deployment files (state preserved)..."
    _sync_tree "$staged" "$SUPABASE_DIR" "${SUPABASE_PRESERVE[@]}"

    # The staged tree may ship its own .env; make sure ours wins.
    cp "$backup_env" "${SUPABASE_DIR}/.env"
    chmod 600 "${SUPABASE_DIR}/.env" 2>/dev/null || true

    if [[ -s "${staging}/_version" ]]; then
        cp "${staging}/_version" "${SUPABASE_DIR}/.supabase-version"
    fi

    log_ok "Supabase deployment files updated"
    return 0
}
