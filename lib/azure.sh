#!/usr/bin/env bash
# lib/azure.sh - Azure AD (Microsoft Entra ID) sign-in via Supabase Auth.
#
# Upstream ships GOTRUE_EXTERNAL_AZURE_* wiring in docker-compose.yml commented
# out (its own .env.example says so: "You must ALSO uncomment the matching
# GOTRUE_EXTERNAL_* lines in docker-compose.yml"). Setting the .env values
# alone does nothing until those lines are live, so this module also patches
# the compose file - the one place this installer edits vendored deployment
# scaffolding rather than only .env.
#
# The client secret is a real credential from the operator, unlike everything
# else this installer touches: it is entered here, never generated. It is
# written straight to supabase/.env (chmod 600) and never to installer.env,
# following the same separation as every other Supabase secret, and never
# passed to run_logged or anything else that writes to SO_LOG_FILE.
# shellcheck shell=bash

# Non-secret config, persisted in installer.env.
ENABLE_AZURE_AD="false"
AZURE_CLIENT_ID=""
AZURE_TENANT_ID=""

# Set only for the duration of a single interactive prompt+apply in the same
# run; never persisted to installer.env and never logged.
AZURE_CLIENT_SECRET=""

_azure_redirect_uri() { printf '%s/callback' "${API_EXTERNAL_URL}"; }

azure_prompt_config() {
    section "Azure AD (Microsoft Entra ID) Sign-In"

    if ! confirm "Enable Azure AD sign-in?" n; then
        ENABLE_AZURE_AD="false"
        return 0
    fi
    ENABLE_AZURE_AD="true"

    printf '\nRegister (or find) an app registration in Microsoft Entra ID first, with:\n'
    printf '  Redirect URI: %s\n\n' "$(_azure_redirect_uri)"

    prompt_default AZURE_CLIENT_ID "Application (client) ID" "$AZURE_CLIENT_ID"
    prompt_secret  AZURE_CLIENT_SECRET "Client secret" ""
    prompt_default AZURE_TENANT_ID "Directory (tenant) ID (blank = any org, Azure's 'common' endpoint)" "$AZURE_TENANT_ID"

    if [[ -z "$AZURE_CLIENT_ID" || -z "$AZURE_CLIENT_SECRET" ]]; then
        log_warn "Client ID or secret left blank; Azure AD sign-in will not be enabled."
        ENABLE_AZURE_AD="false"
    fi
    return 0
}

# Write the non-secret + secret values into supabase/.env. Safe to call on
# every install/update: when no fresh secret was entered in this run (e.g. a
# Supabase update, which never re-prompts), AZURE_CLIENT_SECRET is empty and
# the value already in .env - set once, at the run that first enabled this -
# is left untouched, exactly like every other generated Supabase secret.
azure_apply_config() {
    local env_file="${SUPABASE_DIR}/.env"
    [[ -f "$env_file" ]] || { log_error "Missing ${env_file}"; return 1; }

    if [[ "$ENABLE_AZURE_AD" == "true" ]]; then
        env_set "$env_file" AZURE_ENABLED "true"
        [[ -n "$AZURE_CLIENT_ID" ]] && env_set "$env_file" AZURE_CLIENT_ID "$AZURE_CLIENT_ID"
        [[ -n "$AZURE_CLIENT_SECRET" ]] && env_set "$env_file" AZURE_SECRET "$AZURE_CLIENT_SECRET"
        if [[ -n "$AZURE_TENANT_ID" ]]; then
            env_set "$env_file" AZURE_URL "https://login.microsoftonline.com/${AZURE_TENANT_ID}"
        fi
    else
        env_set "$env_file" AZURE_ENABLED "false"
    fi

    chmod 600 "$env_file" 2>/dev/null || true
    log_ok "Azure AD configuration applied"
    return 0
}

# Uncomment upstream's GOTRUE_EXTERNAL_AZURE_* lines in docker-compose.yml, and
# add the one wiring upstream does not ship at all: GOTRUE_EXTERNAL_AZURE_URL,
# which is how gotrue points at a specific tenant instead of the 'common'
# multi-tenant endpoint (supabase/auth's provider config exposes this as the
# generic per-provider "URL" field; upstream's compose simply never wires it
# for Azure). Idempotent: a line already uncommented, or an URL line already
# present, is left alone.
azure_patch_compose() {
    [[ "$ENABLE_AZURE_AD" == "true" ]] || return 0

    local compose="${SUPABASE_DIR}/docker-compose.yml"
    [[ -f "$compose" ]] || { log_error "Missing ${compose}"; return 1; }

    if ! grep -q 'GOTRUE_EXTERNAL_AZURE_REDIRECT_URI' "$compose"; then
        log_warn "This Supabase release's docker-compose.yml has no Azure AD wiring to enable."
        log_warn "Azure AD sign-in was configured in .env but could not be wired into the auth container."
        return 1
    fi

    local tmp
    tmp="$(mktemp)"
    awk -v have_url="$(grep -c 'GOTRUE_EXTERNAL_AZURE_URL' "$compose")" '
        /GOTRUE_EXTERNAL_AZURE_(ENABLED|CLIENT_ID|SECRET|REDIRECT_URI):/ {
            sub(/#[[:space:]]*/, "")
            print
            if ($0 ~ /GOTRUE_EXTERNAL_AZURE_REDIRECT_URI:/ && have_url == 0) {
                indent = $0
                sub(/[^ \t].*/, "", indent)
                print indent "GOTRUE_EXTERNAL_AZURE_URL: ${AZURE_URL:-}"
            }
            next
        }
        { print }
    ' "$compose" >"$tmp"

    if ! cmp -s "$tmp" "$compose"; then
        cat "$tmp" >"$compose"
        log_ok "Azure AD environment wired into docker-compose.yml"
    fi
    rm -f "$tmp"
    return 0
}

azure_enabled() { [[ "$ENABLE_AZURE_AD" == "true" ]]; }
