#!/usr/bin/env bash
# lib/frontend.sh - application environment, Docker image and container.
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Non-empty (a human-readable reason) when this port cannot be used for the
# frontend; empty when it is safe to use.
_frontend_port_conflict() {
    local port="$1" reserved
    for reserved in $(supabase_reserved_ports); do
        if [[ "$port" == "$reserved" ]]; then
            printf 'is reserved by Supabase - its own compose file always publishes it'
            return 0
        fi
    done
    if port_in_use "$port"; then
        printf 'is already in use on this host'
        return 0
    fi
    return 1
}

# Interactive prompt for the frontend's published port. Validated against
# every port Supabase's own compose file always publishes (its gateway and
# pooler, upstream's choice, not something this installer can move) and
# against whatever else is already listening, so a collision is caught here
# instead of surfacing later as a raw "port is already allocated" from Docker.
frontend_prompt_config() {
    section "Frontend Port"

    local conflict
    while true; do
        prompt_default APP_PORT "Frontend port" "$APP_PORT"

        conflict="$(_frontend_port_conflict "$APP_PORT")" || break
        log_warn "Port ${APP_PORT} ${conflict}."
        if [[ "$SO_ASSUME_YES" == "true" || ! -t 0 ]]; then
            die "Port ${APP_PORT} cannot be used and this run cannot prompt for another. Set APP_PORT to a free port in ${CONFIG_FILE} and re-run."
        fi
    done
}

# ---------------------------------------------------------------------------
# Application environment
# ---------------------------------------------------------------------------

# Generate app/.env.local from the live Supabase configuration.
#
# Keys the installer owns are always refreshed (they are derived values, and a
# stale Supabase URL is a broken deployment). Any other key an operator added
# is preserved.
#
# .env.local rather than .env: the application repository *tracks* .env, so
# writing there leaves the checkout permanently dirty and the next
# `git merge --ff-only` in `update app` aborts with "the local checkout has
# diverged". Vite reads .env.local with higher precedence than .env, and the
# repository's .gitignore already covers *.local, so this overrides the
# committed values without touching version control.
app_env_generate() {
    local env_file="${APP_DIR}/.env.local"
    local pub_key project_id

    if ! pub_key="$(supabase_publishable_key)"; then
        log_error "Could not read the Supabase publishable (anon) key from ${SUPABASE_DIR}/.env"
        return 1
    fi
    project_id="local"

    [[ -f "$env_file" ]] || : >"$env_file"

    # NOTE: the service-role key is deliberately absent. Anything in a Vite
    # build is shipped to the browser, so a service-role key here would hand
    # every visitor full database access.
    env_set "$env_file" PORT                          "$APP_PORT"
    env_set "$env_file" NODE_ENV                      "production"
    env_set "$env_file" SUPABASE_PROJECT_ID           "\"${project_id}\""
    env_set "$env_file" SUPABASE_PUBLISHABLE_KEY      "\"${pub_key}\""
    env_set "$env_file" SUPABASE_URL                  "\"${SUPABASE_PUBLIC_URL}\""
    env_set "$env_file" VITE_SUPABASE_PROJECT_ID      "\"${project_id}\""
    env_set "$env_file" VITE_SUPABASE_PUBLISHABLE_KEY "\"${pub_key}\""
    env_set "$env_file" VITE_SUPABASE_URL             "\"${SUPABASE_PUBLIC_URL}\""

    chmod 640 "$env_file" 2>/dev/null || true
    log_ok "Application environment written to ${env_file}"

    # An earlier installer version wrote the tracked .env directly. Say so once,
    # rather than letting `update app` fail later with a confusing merge error.
    if repo_is_cloned && [[ -n "$(app_git status --porcelain -- .env 2>/dev/null)" ]]; then
        log_warn "The checkout has local modifications to the tracked .env file."
        log_warn "This installer no longer writes it. Discard them with:"
        log_warn "  git -C ${APP_DIR} checkout -- .env"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Build assets
# ---------------------------------------------------------------------------

# The Dockerfile belongs in the application repository. Until it is committed
# there, the installer supplies one so deployment is not blocked.
frontend_provision_build_files() {
    local src="${SO_ASSETS_DIR}/app"

    if [[ -f "${APP_DIR}/Dockerfile" ]]; then
        log_ok "Using the Dockerfile from the application repository"
    else
        cp "${src}/Dockerfile" "${APP_DIR}/Dockerfile" || return 1
        log_info "Repository has no Dockerfile; using the installer's production template."
    fi

    [[ -f "${APP_DIR}/.dockerignore" ]] || cp "${src}/dockerignore" "${APP_DIR}/.dockerignore"
    return 0
}

frontend_image_tag()  { printf '%s:%s' "$APP_IMAGE_NAME" "$(repo_short_commit)"; }
frontend_image_latest() { printf '%s:latest' "$APP_IMAGE_NAME"; }

# Build the production image, tagged with the Git SHA so a previous image is
# always available to roll back to.
frontend_build_image() {
    local tag latest
    tag="$(frontend_image_tag)"
    latest="$(frontend_image_latest)"

    frontend_provision_build_files || return 1

    log_info "Building Docker image ${tag}..."
    # Supabase URLs and keys are not build-time inputs: the app reads them from
    # process.env at runtime via /runtime-config.js, and frontend_run_container
    # passes them as container env vars. See frontend_run_container below.
    if ! run_logged "docker build" docker build \
            --build-arg "APP_PORT=${APP_PORT}" \
            -t "$tag" -t "$latest" \
            -f "${APP_DIR}/Dockerfile" \
            "$APP_DIR"; then
        return 1
    fi
    log_ok "Image built: ${tag}"
    return 0
}

# ---------------------------------------------------------------------------
# Container lifecycle
# ---------------------------------------------------------------------------

container_exists()  { docker container inspect "$1" >/dev/null 2>&1; }
container_running() { [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]; }

# Where the published port is bound. Defaults to loopback so the container is
# reachable by a reverse proxy on this host but not from the public internet.
frontend_bind_address() {
    printf '%s' "${APP_BIND:-127.0.0.1}"
}

# Start a container from an image. frontend_run_container <name> <image> <host-port>
frontend_run_container() {
    local name="$1" image="$2" host_port="$3" network bind attached="false"
    network="$(supabase_network_name)"
    bind="$(frontend_bind_address)"

    docker rm -f "$name" >/dev/null 2>&1 || true

    # Attaching to the Supabase network lets a dockerised reverse proxy route to
    # this container by name instead of going back out through the host, and is
    # also how the Nitro server reaches the Supabase gateway (see below).
    if docker network inspect "$network" >/dev/null 2>&1; then
        attached="true"
    else
        log_warn "Supabase network '${network}' not found; starting on the default bridge."
    fi

    # The image ships with no credentials in it on purpose, so everything the
    # server needs has to arrive here. This is not just the browser's
    # configuration: the app is a TanStack Start/Nitro server, and its
    # server-side code reads SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY from
    # process.env (src/integrations/supabase/client.server.ts). Without them
    # every server function and /api/health fail with "Missing Supabase
    # environment variable(s)" while the container still serves HTML, so the
    # deployment looks up but cannot talk to the database.
    local pub_key svc_key server_url
    if ! pub_key="$(supabase_publishable_key)"; then
        log_error "Could not read the Supabase publishable (anon) key from ${SUPABASE_DIR}/.env"
        return 1
    fi
    if ! svc_key="$(supabase_service_role_key)"; then
        log_error "Could not read the Supabase service-role key from ${SUPABASE_DIR}/.env"
        return 1
    fi

    # SUPABASE_URL is the endpoint the *server* dials, which is not the same as
    # the one the browser uses. SUPABASE_PUBLIC_URL is routinely
    # http://localhost:8000, and inside this container localhost is the
    # container itself, not the gateway. Address the gateway by its Compose
    # service name while we are on the Supabase network; only fall back to the
    # public URL when we are not, where it is the best guess available.
    if [[ "$attached" == "true" ]]; then
        server_url="http://api-gw:$(supabase_kong_port)"
    else
        server_url="$SUPABASE_PUBLIC_URL"
    fi

    # Runtime environment is passed explicitly rather than with --env-file:
    # Docker does not strip quotes from an env file, so the quoted values in
    # app/.env (which is written in the format the application's own tooling
    # expects) would arrive with literal " characters around them.
    local args=(
        run -d
        --name "$name"
        --restart unless-stopped
        -e "NODE_ENV=production"
        -e "APP_PORT=${APP_PORT}"
        # Nitro's node-server listens on PORT/HOST. HOST must be 0.0.0.0 or the
        # server binds to loopback *inside* the container and the published port
        # reaches nothing.
        -e "PORT=${APP_PORT}"
        -e "HOST=0.0.0.0"
        -e "SUPABASE_URL=${server_url}"
        # The browser gets this one, via the /runtime-config.js server route.
        -e "SUPABASE_PUBLIC_URL=${SUPABASE_PUBLIC_URL}"
        # Both keys are passed by name, not as NAME=value: run_logged writes the
        # argv it is given into the installer log, and the service-role key is a
        # full-access credential that must not be persisted there.
        -e SUPABASE_PUBLISHABLE_KEY
        -e SUPABASE_SERVICE_ROLE_KEY
        -p "${bind}:${host_port}:${APP_PORT}"
    )
    if [[ "$attached" == "true" ]]; then
        args+=(--network "$network")
    fi
    args+=("$image")

    local rc=0
    export SUPABASE_PUBLISHABLE_KEY="$pub_key"
    export SUPABASE_SERVICE_ROLE_KEY="$svc_key"
    run_logged "start ${name}" docker "${args[@]}" || rc=$?
    unset SUPABASE_PUBLISHABLE_KEY SUPABASE_SERVICE_ROLE_KEY
    return "$rc"
}

frontend_check_http() {
    local port="${1:-$APP_PORT}" code
    code="$(_http_code "http://127.0.0.1:${port}/")"
    [[ "$code" =~ ^(200|301|302)$ ]]
}

frontend_health_check() {
    local port="${1:-$APP_PORT}"
    log_info "Checking the frontend on port ${port}..."
    if wait_for 90 3 frontend_check_http "$port"; then
        log_ok "Frontend responding"
        return 0
    fi
    log_error "Frontend did not answer on port ${port}"
    docker logs --tail 40 "$APP_CONTAINER_NAME" 2>&1 | tail -n 40 >&2 || true
    return 1
}

# Find a free TCP port for the staging container.
_free_port() {
    local port
    for port in $(seq 39000 39050); do
        port_in_use "$port" || { printf '%s' "$port"; return 0; }
    done
    printf '39099'
}

# Deploy the new image without destroying the running one first.
#
#   verify the new image on a staging container
#        -> only then replace the live container
#        -> if the replacement is unhealthy, restore the previous image
frontend_deploy() {
    local image staging_name staging_port previous_image
    image="$(frontend_image_tag)"
    staging_name="${APP_CONTAINER_NAME}-staging"
    staging_port="$(_free_port)"
    previous_image="$(state_get APP_IMAGE '')"

    # 1. Prove the new image actually serves traffic.
    log_info "Verifying the new image on a staging container..."
    if ! frontend_run_container "$staging_name" "$image" "$staging_port"; then
        docker rm -f "$staging_name" >/dev/null 2>&1 || true
        return 1
    fi
    if ! wait_for 90 3 frontend_check_http "$staging_port"; then
        log_error "The new image failed its health check; the running deployment was left untouched."
        docker logs --tail 40 "$staging_name" 2>&1 | tail -n 40 >&2 || true
        docker rm -f "$staging_name" >/dev/null 2>&1 || true
        return 1
    fi
    log_ok "New image verified"
    docker rm -f "$staging_name" >/dev/null 2>&1 || true

    # 2. Swap the live container over.
    if container_exists "$APP_CONTAINER_NAME"; then
        log_info "Replacing the running container..."
        docker rm -f "$APP_CONTAINER_NAME" >/dev/null 2>&1 || true
    fi

    if frontend_run_container "$APP_CONTAINER_NAME" "$image" "$APP_PORT" \
        && wait_for 90 3 frontend_check_http "$APP_PORT"; then
        log_ok "Sentinel Ops frontend deployed (${image})"
        state_set APP_IMAGE "$image"
        [[ -n "$previous_image" && "$previous_image" != "$image" ]] && \
            state_set PREVIOUS_APP_IMAGE "$previous_image"
        return 0
    fi

    # 3. Roll back to the previous image if we have one.
    log_error "The replacement container is unhealthy."
    if [[ -n "$previous_image" ]] && docker image inspect "$previous_image" >/dev/null 2>&1; then
        log_warn "Rolling back to ${previous_image}..."
        if frontend_run_container "$APP_CONTAINER_NAME" "$previous_image" "$APP_PORT" \
            && wait_for 60 3 frontend_check_http "$APP_PORT"; then
            log_ok "Rolled back to ${previous_image}"
        else
            log_error "Rollback also failed. The frontend is down."
        fi
    else
        log_error "No previous image recorded; cannot roll back automatically."
    fi
    return 1
}

frontend_deployed_image() { state_get APP_IMAGE ''; }
