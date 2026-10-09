#!/usr/bin/env bash
# lib/hardening.sh - optional Supabase Auth (gotrue) hardening.
#
# Five independent, opt-in settings, all off by default so an install that
# skips the prompts behaves exactly as before:
#
#   signup           GOTRUE_DISABLE_SIGNUP - accounts are created by admins only
#   password-policy  minimum length plus lower/upper/digit/symbol classes
#   hibp             reject passwords found in known breaches (Pwned Passwords)
#   captcha          Cloudflare Turnstile on password sign-in
#   rate-limit       key gotrue's per-IP rate limits on a header the reverse
#                    proxy sets - without one, self-hosted gotrue applies no
#                    per-IP limit at all (performRateLimitingWithHeader returns
#                    early when GOTRUE_RATE_LIMIT_HEADER is empty)
#
# Upstream's docker-compose.yml already wires GOTRUE_DISABLE_SIGNUP to
# ${DISABLE_SIGNUP}, so "signup" is a plain .env setting. None of the others
# appear in upstream's compose file at all, so setting them in .env alone does
# nothing. They are delivered through a generated Compose overlay instead,
# registered in COMPOSE_FILE the same way upstream's own optional overlays are
# (docs/DECISIONS.md #28). The overlay is regenerated on every apply, so it
# never drifts, and `update supabase` leaves it alone because upstream does
# not ship a file by that name.
#
# The Turnstile secret is the one credential here. Like the Azure AD client
# secret it is entered by the operator, written only to supabase/.env
# (chmod 600) and interpolated into the overlay by reference - it never
# appears in the overlay, in installer.env or in the log.
# shellcheck shell=bash

HARDENING_OVERLAY="docker-compose.sentinel-auth.yml"
HARDENING_FEATURES=(signup password-policy hibp captcha rate-limit)

# A dedicated header rather than X-Forwarded-For or X-Real-IP: Envoy appends to
# X-Forwarded-For (so its first entry is whatever the client sent) and Kong
# overwrites X-Real-IP with the proxy's own address (so every user would share
# one bucket). A header only the edge proxy sets passes through both gateways
# untouched. See docs/AUTH-HARDENING.md.
HARDENING_DEFAULT_RATE_LIMIT_HEADER="X-Sentinel-Client-IP"

# The same character classes as hosted Supabase's
# "lower_upper_letters_digits_symbols" option. Sets are ":"-separated; the
# colon inside the symbol set is escaped as "\:" (gotrue's
# PasswordRequiredCharacters.Decode joins it back).
HARDENING_PASSWORD_CHARACTERS='abcdefghijklmnopqrstuvwxyz:ABCDEFGHIJKLMNOPQRSTUVWXYZ:0123456789:!@#$%^&*()_+-=[]{};'"'"'\:"|<>?,./`~'

# Non-secret config, persisted in installer.env.
AUTH_DISABLE_SIGNUP="false"
AUTH_PASSWORD_POLICY="false"
AUTH_PASSWORD_MIN_LENGTH="12"
AUTH_HIBP_ENABLED="false"
AUTH_HIBP_FAIL_CLOSED="false"
AUTH_CAPTCHA_ENABLED="false"
TURNSTILE_SITE_KEY=""
AUTH_RATE_LIMIT_HEADER=""
AUTH_RATE_LIMIT_TOKEN=""

# Set only for the duration of a single interactive prompt+apply in the same
# run; never persisted to installer.env and never logged.
TURNSTILE_SECRET_KEY=""

_hardening_overlay_path() { printf '%s/%s' "$SUPABASE_DIR" "$HARDENING_OVERLAY"; }

# "signup|password-policy|..." for usage messages.
_hardening_feature_list() {
    local IFS='|'
    printf '%s' "${HARDENING_FEATURES[*]}"
}

hardening_feature_known() {
    local f
    for f in "${HARDENING_FEATURES[@]}"; do
        [[ "$f" == "$1" ]] && return 0
    done
    return 1
}

# True when any setting that needs the overlay is on.
hardening_any_overlay_feature() {
    [[ "$AUTH_PASSWORD_POLICY" == "true" || "$AUTH_HIBP_ENABLED" == "true" \
        || "$AUTH_CAPTCHA_ENABLED" == "true" || -n "$AUTH_RATE_LIMIT_HEADER" ]]
}

hardening_feature_enabled() {
    case "$1" in
        signup)          [[ "$AUTH_DISABLE_SIGNUP" == "true" ]] ;;
        password-policy) [[ "$AUTH_PASSWORD_POLICY" == "true" ]] ;;
        hibp)            [[ "$AUTH_HIBP_ENABLED" == "true" ]] ;;
        captcha)         [[ "$AUTH_CAPTCHA_ENABLED" == "true" ]] ;;
        rate-limit)      [[ -n "$AUTH_RATE_LIMIT_HEADER" ]] ;;
        *)               return 1 ;;
    esac
}

# Does the application checkout read the Turnstile site key yet? Enabling
# CAPTCHA before the login form sends a token locks every password user out.
# 0 = yes, 1 = no, 2 = cannot tell (no checkout yet).
_hardening_app_supports_captcha() {
    [[ -n "${APP_DIR:-}" && -d "${APP_DIR}/src" ]] || return 2
    grep -rqs 'TURNSTILE_SITE_KEY' "${APP_DIR}/src"
}

# ---------------------------------------------------------------------------
# Per-feature enable/disable. Enabling may prompt for the details a feature
# needs; it returns non-zero (leaving the feature off) if those are missing.
# ---------------------------------------------------------------------------

hardening_enable_feature() {
    case "$1" in
        signup)
            if [[ "${ENABLE_AZURE_AD:-false}" == "true" ]]; then
                log_warn "Azure AD sign-in is enabled. With sign-up disabled, gotrue may refuse a"
                log_warn "first-time SSO user who has no account yet - provision them first"
                log_warn "(sync-employees) and test one SSO login after enabling this."
            fi
            AUTH_DISABLE_SIGNUP="true"
            ;;
        password-policy)
            prompt_default AUTH_PASSWORD_MIN_LENGTH "Minimum password length" "${AUTH_PASSWORD_MIN_LENGTH:-12}"
            if ! [[ "$AUTH_PASSWORD_MIN_LENGTH" =~ ^[0-9]+$ ]] || (( AUTH_PASSWORD_MIN_LENGTH < 6 )); then
                log_warn "Minimum length must be a number of at least 6; using 12."
                AUTH_PASSWORD_MIN_LENGTH="12"
            fi
            AUTH_PASSWORD_POLICY="true"
            log_info "Only applies when a password is set; existing passwords keep working until changed."
            ;;
        hibp)
            log_info "Each new password's hash prefix is checked against api.pwnedpasswords.com."
            if confirm "Reject the password when that API cannot be reached (fail closed)?" n; then
                AUTH_HIBP_FAIL_CLOSED="true"
            else
                AUTH_HIBP_FAIL_CLOSED="false"
            fi
            AUTH_HIBP_ENABLED="true"
            ;;
        captcha)
            local supported=0
            _hardening_app_supports_captcha || supported=$?
            if (( supported != 0 )); then
                if (( supported == 1 )); then
                    log_warn "The application checkout does not read TURNSTILE_SITE_KEY yet."
                else
                    log_warn "Cannot tell whether the application supports Turnstile (not checked out yet)."
                fi
                log_warn "If the login form does not send a CAPTCHA token, every password sign-in"
                log_warn "will be rejected once this is on."
                confirm "Enable CAPTCHA anyway?" n || return 1
            fi
            printf '\nCreate a Turnstile widget at https://dash.cloudflare.com/?to=/:account/turnstile\n'
            printf 'for the application hostname. Browsers need to reach challenges.cloudflare.com.\n\n'
            prompt_default TURNSTILE_SITE_KEY "Turnstile site key" "$TURNSTILE_SITE_KEY"
            local existing=""
            [[ -f "${SUPABASE_DIR}/.env" ]] && existing="$(env_get "${SUPABASE_DIR}/.env" TURNSTILE_SECRET_KEY 2>/dev/null || true)"
            prompt_secret TURNSTILE_SECRET_KEY "Turnstile secret key" "$existing"
            if [[ -z "$TURNSTILE_SITE_KEY" || -z "$TURNSTILE_SECRET_KEY" ]]; then
                log_warn "Site key or secret left blank; CAPTCHA will not be enabled."
                return 1
            fi
            AUTH_CAPTCHA_ENABLED="true"
            ;;
        rate-limit)
            if [[ "${SITE_URL:-}" != https://* ]]; then
                log_warn "No domain is configured. This only works behind a reverse proxy that sets the"
                log_warn "header below on every request; without it gotrue still applies no per-IP limit."
            fi
            log_info "The reverse proxy must OVERWRITE this header with the client address, e.g. nginx:"
            log_info "  proxy_set_header ${HARDENING_DEFAULT_RATE_LIMIT_HEADER} \$remote_addr;"
            log_info "and the Supabase API port must not be reachable except through that proxy."
            prompt_default AUTH_RATE_LIMIT_HEADER "Client-IP header set by the reverse proxy" \
                "${AUTH_RATE_LIMIT_HEADER:-$HARDENING_DEFAULT_RATE_LIMIT_HEADER}"
            if ! [[ "$AUTH_RATE_LIMIT_HEADER" =~ ^[A-Za-z0-9-]+$ ]]; then
                log_warn "Not a valid header name: ${AUTH_RATE_LIMIT_HEADER}"
                AUTH_RATE_LIMIT_HEADER=""
                return 1
            fi
            ;;
        *)
            log_error "Unknown feature: $1 (valid: ${HARDENING_FEATURES[*]})"
            return 2
            ;;
    esac
    return 0
}

hardening_disable_feature() {
    case "$1" in
        signup)          AUTH_DISABLE_SIGNUP="false" ;;
        password-policy) AUTH_PASSWORD_POLICY="false" ;;
        hibp)            AUTH_HIBP_ENABLED="false"; AUTH_HIBP_FAIL_CLOSED="false" ;;
        captcha)         AUTH_CAPTCHA_ENABLED="false" ;;
        rate-limit)      AUTH_RATE_LIMIT_HEADER="" ;;
        *)
            log_error "Unknown feature: $1 (valid: ${HARDENING_FEATURES[*]})"
            return 2
            ;;
    esac
    return 0
}

hardening_prompt_config() {
    section "Auth hardening (all optional)"

    if confirm "Disable public sign-up (accounts are created by admins only)?" n; then
        hardening_enable_feature signup
    else
        AUTH_DISABLE_SIGNUP="false"
    fi
    if confirm "Enforce a strong password policy (length + upper/lower/digit/symbol)?" n; then
        hardening_enable_feature password-policy
    else
        AUTH_PASSWORD_POLICY="false"
    fi
    if confirm "Reject passwords found in known data breaches (needs outbound HTTPS)?" n; then
        hardening_enable_feature hibp
    else
        AUTH_HIBP_ENABLED="false"
    fi
    if confirm "Require a CAPTCHA (Cloudflare Turnstile) on password sign-in?" n; then
        hardening_enable_feature captcha || AUTH_CAPTCHA_ENABLED="false"
    else
        AUTH_CAPTCHA_ENABLED="false"
    fi
    if confirm "Rate-limit sign-in per client IP (needs a reverse proxy)?" n; then
        hardening_enable_feature rate-limit || AUTH_RATE_LIMIT_HEADER=""
    else
        AUTH_RATE_LIMIT_HEADER=""
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Applying
# ---------------------------------------------------------------------------

# Quote a literal for a YAML single-quoted scalar that Compose will not
# interpolate: ' doubles, and $ becomes $$ (Compose interpolates inside quoted
# YAML strings too).
_hardening_yaml_literal() {
    local v="$1"
    v="${v//\'/\'\'}"
    v="${v//\$/\$\$}"
    printf "'%s'" "$v"
}

# Print the overlay for the current settings.
hardening_render_overlay() {
    printf '# Generated by sentinel-ops (lib/hardening.sh). Do not edit: it is rewritten\n'
    printf '# on every install, `update supabase` and `sentinel-ops auth` run.\n'
    printf '# See docs/AUTH-HARDENING.md.\n'
    printf 'services:\n'
    printf '  auth:\n'
    printf '    environment:\n'
    if [[ "$AUTH_PASSWORD_POLICY" == "true" ]]; then
        printf '      GOTRUE_PASSWORD_MIN_LENGTH: %s\n' "$(_hardening_yaml_literal "$AUTH_PASSWORD_MIN_LENGTH")"
        printf '      GOTRUE_PASSWORD_REQUIRED_CHARACTERS: %s\n' "$(_hardening_yaml_literal "$HARDENING_PASSWORD_CHARACTERS")"
    fi
    if [[ "$AUTH_HIBP_ENABLED" == "true" ]]; then
        printf "      GOTRUE_PASSWORD_HIBP_ENABLED: 'true'\n"
        printf '      GOTRUE_PASSWORD_HIBP_FAIL_CLOSED: %s\n' "$(_hardening_yaml_literal "$AUTH_HIBP_FAIL_CLOSED")"
    fi
    if [[ "$AUTH_CAPTCHA_ENABLED" == "true" ]]; then
        printf "      GOTRUE_SECURITY_CAPTCHA_ENABLED: 'true'\n"
        printf "      GOTRUE_SECURITY_CAPTCHA_PROVIDER: 'turnstile'\n"
        # By reference: the secret stays in supabase/.env. ':?' makes Compose
        # refuse to start with a clear message instead of gotrue crash-looping
        # on "captcha provider secret is empty".
        # Double-quoted so the message's punctuation cannot break the YAML.
        printf '      GOTRUE_SECURITY_CAPTCHA_SECRET: "${TURNSTILE_SECRET_KEY:?TURNSTILE_SECRET_KEY is missing from supabase/.env - add it or run sentinel-ops auth disable captcha}"\n'
    fi
    if [[ -n "$AUTH_RATE_LIMIT_HEADER" ]]; then
        printf '      GOTRUE_RATE_LIMIT_HEADER: %s\n' "$(_hardening_yaml_literal "$AUTH_RATE_LIMIT_HEADER")"
        if [[ "$AUTH_RATE_LIMIT_TOKEN" =~ ^[0-9]+$ ]]; then
            printf '      GOTRUE_RATE_LIMIT_TOKEN_REFRESH: %s\n' "$(_hardening_yaml_literal "$AUTH_RATE_LIMIT_TOKEN")"
        fi
    fi
}

# Add or remove the overlay from COMPOSE_FILE in supabase/.env, keeping every
# other entry (the logs overlay, a pg17 overlay) and their order.
_hardening_compose_file_set() {
    local want="$1" env_file="${SUPABASE_DIR}/.env" current entry out="" entries=()
    current="$(env_get "$env_file" COMPOSE_FILE 2>/dev/null || true)"
    # Nothing to remove: leave an .env that never had the overlay byte-for-byte
    # as it was, including one with no COMPOSE_FILE line at all.
    if [[ "$want" != "true" && ":${current}:" != *":${HARDENING_OVERLAY}:"* ]]; then
        return 0
    fi
    [[ -n "$current" ]] || current="docker-compose.yml"

    IFS=':' read -r -a entries <<<"$current"
    for entry in "${entries[@]}"; do
        [[ -z "$entry" || "$entry" == "$HARDENING_OVERLAY" ]] && continue
        out="${out:+${out}:}${entry}"
    done
    if [[ "$want" == "true" ]]; then
        out="${out}:${HARDENING_OVERLAY}"
    fi

    [[ "$out" == "$(env_get "$env_file" COMPOSE_FILE 2>/dev/null || true)" ]] || \
        env_set "$env_file" COMPOSE_FILE "$out"
}

# Everything hardening_write_overlay can change, as one string - lets a caller
# tell whether a re-apply actually changed anything (and so needs a restart).
_hardening_fingerprint() {
    printf '%s|%s|%s' \
        "$(env_get "${SUPABASE_DIR}/.env" DISABLE_SIGNUP 2>/dev/null || true)" \
        "$(env_get "${SUPABASE_DIR}/.env" COMPOSE_FILE 2>/dev/null || true)" \
        "$(cat "$(_hardening_overlay_path)" 2>/dev/null || true)"
}

# Write (or remove) the overlay and register (or unregister) it.
hardening_write_overlay() {
    local env_file="${SUPABASE_DIR}/.env" overlay
    [[ -f "$env_file" ]] || { log_error "Missing ${env_file}"; return 1; }
    overlay="$(_hardening_overlay_path)"

    if hardening_any_overlay_feature; then
        local tmp
        tmp="$(mktemp)"
        hardening_render_overlay >"$tmp"
        if ! cmp -s "$tmp" "$overlay" 2>/dev/null; then
            cat "$tmp" >"$overlay"
        fi
        rm -f "$tmp"
        _hardening_compose_file_set true
    else
        _hardening_compose_file_set false
        rm -f "$overlay"
    fi
    return 0
}

# Write the .env side and the overlay. Safe to call on every install/update:
# when no fresh secret was entered in this run, the one already in .env is
# kept, exactly like the Azure AD client secret.
hardening_apply_config() {
    local env_file="${SUPABASE_DIR}/.env"
    [[ -f "$env_file" ]] || { log_error "Missing ${env_file}"; return 1; }

    # Only ever turned on here. Turning it off is an explicit
    # `sentinel-ops auth disable signup`, so an operator who set
    # DISABLE_SIGNUP=true by hand before this feature existed keeps it.
    if [[ "$AUTH_DISABLE_SIGNUP" == "true" ]]; then
        env_set "$env_file" DISABLE_SIGNUP "true"
    fi
    if [[ -n "$TURNSTILE_SECRET_KEY" ]]; then
        env_set "$env_file" TURNSTILE_SECRET_KEY "$TURNSTILE_SECRET_KEY"
    fi

    if [[ "$AUTH_CAPTCHA_ENABLED" == "true" && -z "$(env_get "$env_file" TURNSTILE_SECRET_KEY 2>/dev/null || true)" ]]; then
        log_warn "CAPTCHA is enabled but supabase/.env has no TURNSTILE_SECRET_KEY; disabling it."
        AUTH_CAPTCHA_ENABLED="false"
    fi

    hardening_write_overlay || return 1
    chmod 600 "$env_file" 2>/dev/null || true
    log_ok "Auth hardening configuration applied"
    return 0
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

hardening_status() {
    local f label detail
    for f in "${HARDENING_FEATURES[@]}"; do
        case "$f" in
            signup)          label="Public sign-up";    detail="disabled (admin-created accounts only)" ;;
            password-policy) label="Password policy";   detail="min ${AUTH_PASSWORD_MIN_LENGTH}, upper/lower/digit/symbol" ;;
            hibp)            label="Breached passwords"; detail="rejected (fail-$([[ "$AUTH_HIBP_FAIL_CLOSED" == "true" ]] && printf closed || printf open))" ;;
            captcha)         label="CAPTCHA";           detail="Turnstile" ;;
            rate-limit)      label="Per-IP rate limit"; detail="keyed on ${AUTH_RATE_LIMIT_HEADER}" ;;
        esac
        if hardening_feature_enabled "$f"; then
            status_line "$label" "ok" "$detail"
        else
            status_line "$label" "" "off"
        fi
    done
    return 0
}
