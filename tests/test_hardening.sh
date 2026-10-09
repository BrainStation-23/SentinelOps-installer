#!/usr/bin/env bash
# Exercise the auth hardening overlay and its COMPOSE_FILE registration: pure
# file transforms, tested against a fixture without Docker or a live stack.
set -uo pipefail

ROOT="${1:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/hardening.sh"

pass=0; fail=0
check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        printf 'PASS  %s\n' "$desc"; pass=$((pass+1))
    else
        printf 'FAIL  %s\n        expected: [%s]\n        actual:   [%s]\n' "$desc" "$expected" "$actual"
        fail=$((fail+1))
    fi
}

T="$(mktemp -d)"
export SUPABASE_DIR="$T"
SO_ASSUME_YES="true"
ENV="${T}/.env"
OVERLAY="${T}/${HARDENING_OVERLAY}"

_reset() {
    printf 'COMPOSE_FILE=docker-compose.yml\nDISABLE_SIGNUP=false\nJWT_SECRET=x\n' >"$ENV"
    rm -f "$OVERLAY"
    AUTH_DISABLE_SIGNUP="false"; AUTH_PASSWORD_POLICY="false"; AUTH_PASSWORD_MIN_LENGTH="12"
    AUTH_HIBP_ENABLED="false"; AUTH_HIBP_FAIL_CLOSED="false"
    AUTH_CAPTCHA_ENABLED="false"; TURNSTILE_SITE_KEY=""; TURNSTILE_SECRET_KEY=""
    AUTH_RATE_LIMIT_HEADER=""; AUTH_RATE_LIMIT_TOKEN=""
}

# --- everything off: nothing changes compared with today -------------------
_reset
ORIG="$(cat "$ENV")"
hardening_apply_config >/dev/null 2>&1
check "all off leaves .env untouched" "$ORIG" "$(cat "$ENV")"
check "all off writes no overlay" "absent" "$([[ -e "$OVERLAY" ]] && printf present || printf absent)"

# --- signup is a plain .env setting, no overlay ------------------------------
_reset
AUTH_DISABLE_SIGNUP="true"
hardening_apply_config >/dev/null 2>&1
check "signup sets DISABLE_SIGNUP" "true" "$(env_get "$ENV" DISABLE_SIGNUP)"
check "signup alone needs no overlay" "docker-compose.yml" "$(env_get "$ENV" COMPOSE_FILE)"

# Turning the flag off must not flip an operator's own DISABLE_SIGNUP=true.
AUTH_DISABLE_SIGNUP="false"
hardening_apply_config >/dev/null 2>&1
check "apply never re-enables sign-up on its own" "true" "$(env_get "$ENV" DISABLE_SIGNUP)"

# --- password policy: values, escaping, registration ------------------------
_reset
AUTH_PASSWORD_POLICY="true"; AUTH_PASSWORD_MIN_LENGTH="14"
hardening_apply_config >/dev/null 2>&1
check "overlay registered last" "docker-compose.yml:${HARDENING_OVERLAY}" "$(env_get "$ENV" COMPOSE_FILE)"
check "min length written" "1" "$(grep -c "^      GOTRUE_PASSWORD_MIN_LENGTH: '14'$" "$OVERLAY")"
chars_line="$(grep 'GOTRUE_PASSWORD_REQUIRED_CHARACTERS' "$OVERLAY")"
check "'\$' escaped as \$\$ for Compose" "1" "$(grep -c '#\$\$%' <<<"$chars_line")"
check "single quote doubled for YAML" "1" "$(grep -c ";''" <<<"$chars_line")"
check "escaped colon kept for gotrue" "1" "$(grep -c '\\:"' <<<"$chars_line")"
check "no HIBP/CAPTCHA keys when off" "0" "$(grep -c -E 'HIBP|CAPTCHA|RATE_LIMIT' "$OVERLAY")"

# Undo the YAML/Compose quoting and compare with what gotrue must receive.
raw="${chars_line#*: \'}"; raw="${raw%\'}"; raw="${raw//\'\'/\'}"; raw="${raw//\$\$/\$}"
check "round-trips to the exact character sets" "$HARDENING_PASSWORD_CHARACTERS" "$raw"

# --- idempotent, and coexists with upstream's logs overlay ------------------
env_set "$ENV" COMPOSE_FILE "docker-compose.yml:${HARDENING_OVERLAY}:docker-compose.logs.yml"
hardening_apply_config >/dev/null 2>&1
hardening_apply_config >/dev/null 2>&1
check "re-apply keeps one entry and the logs overlay" \
    "docker-compose.yml:docker-compose.logs.yml:${HARDENING_OVERLAY}" "$(env_get "$ENV" COMPOSE_FILE)"

# --- all overlay features off again: unregistered and removed ---------------
AUTH_PASSWORD_POLICY="false"
hardening_apply_config >/dev/null 2>&1
check "disabled: overlay unregistered, logs kept" \
    "docker-compose.yml:docker-compose.logs.yml" "$(env_get "$ENV" COMPOSE_FILE)"
check "disabled: overlay file removed" "absent" "$([[ -e "$OVERLAY" ]] && printf present || printf absent)"

# --- an older upstream .env with no COMPOSE_FILE at all ---------------------
_reset
printf 'JWT_SECRET=x\n' >"$ENV"
hardening_apply_config >/dev/null 2>&1
check "no COMPOSE_FILE, all off: .env untouched" "JWT_SECRET=x" "$(cat "$ENV")"
AUTH_HIBP_ENABLED="true"
hardening_apply_config >/dev/null 2>&1
check "no COMPOSE_FILE: base file added first" "docker-compose.yml:${HARDENING_OVERLAY}" "$(env_get "$ENV" COMPOSE_FILE)"
check "HIBP enabled, fail-open by default" "1" "$(grep -c "GOTRUE_PASSWORD_HIBP_FAIL_CLOSED: 'false'" "$OVERLAY")"

# --- CAPTCHA: secret by reference only ---------------------------------------
_reset
AUTH_CAPTCHA_ENABLED="true"; TURNSTILE_SITE_KEY="0x4AAAsite"; TURNSTILE_SECRET_KEY='0x4AAAsecret$value'
hardening_apply_config >/dev/null 2>&1
check "secret written to supabase/.env" '0x4AAAsecret$value' "$(env_get "$ENV" TURNSTILE_SECRET_KEY)"
check "secret not in the overlay" "0" "$(grep -c 'secret\$value' "$OVERLAY")"
check "overlay references the secret, quoted" "1" "$(grep -c '^      GOTRUE_SECURITY_CAPTCHA_SECRET: "\${TURNSTILE_SECRET_KEY:?[^":]*}"$' "$OVERLAY")"
check "provider is turnstile" "1" "$(grep -c "GOTRUE_SECURITY_CAPTCHA_PROVIDER: 'turnstile'" "$OVERLAY")"

# CAPTCHA with no secret anywhere would crash-loop gotrue: refuse it.
_reset
AUTH_CAPTCHA_ENABLED="true"; TURNSTILE_SITE_KEY="0x4AAAsite"
hardening_apply_config >/dev/null 2>&1
check "captcha without a secret is turned off" "false" "$AUTH_CAPTCHA_ENABLED"
check "and writes no overlay" "absent" "$([[ -e "$OVERLAY" ]] && printf present || printf absent)"

# --- rate limit ---------------------------------------------------------------
_reset
AUTH_RATE_LIMIT_HEADER="X-Sentinel-Client-IP"; AUTH_RATE_LIMIT_TOKEN="30"
hardening_apply_config >/dev/null 2>&1
check "rate-limit header written" "1" "$(grep -c "GOTRUE_RATE_LIMIT_HEADER: 'X-Sentinel-Client-IP'" "$OVERLAY")"
check "token limit written" "1" "$(grep -c "GOTRUE_RATE_LIMIT_TOKEN_REFRESH: '30'" "$OVERLAY")"
AUTH_RATE_LIMIT_TOKEN="lots"
hardening_apply_config >/dev/null 2>&1
check "non-numeric token limit ignored" "0" "$(grep -c 'GOTRUE_RATE_LIMIT_TOKEN_REFRESH' "$OVERLAY")"

# --- HIBP health check gates enabling ---------------------------------------
# curl is stubbed: no network in unit tests. Without Supabase installed the
# check runs from the host.
HIBP_BODY=""; HIBP_CURL_RC=0
curl() { printf '%s' "$HIBP_BODY"; return "$HIBP_CURL_RC"; }

_reset
HIBP_BODY=$'0018A45C4D1DEF81644B54AB7F969B88D65:10\r\n1E4C9B93F3F0682250B6CF8331B7EE68FD8:10434004\r\nFFFF:1\r\n'
hardening_enable_feature hibp >/dev/null 2>&1; rc=$?
check "reachable API (CRLF body): enable succeeds" "0|true" "${rc}|${AUTH_HIBP_ENABLED}"
check "checked from the host when Supabase is absent" "this host" "$HIBP_CHECK_FROM"
check "fail-open chosen by default" "false" "$AUTH_HIBP_FAIL_CLOSED"

_reset
HIBP_BODY='<html>Please log in to the guest network</html>'
hardening_enable_feature hibp >/dev/null 2>&1; rc=$?
check "HTTP 200 without the probe hash (captive portal): refused" "1|false" "${rc}|${AUTH_HIBP_ENABLED}"

_reset
HIBP_BODY=""; HIBP_CURL_RC=7
hardening_enable_feature hibp >/dev/null 2>&1; rc=$?
check "unreachable API: refused" "1|false" "${rc}|${AUTH_HIBP_ENABLED}"

# Enabled earlier but unreachable now: status must say so, not report "ok".
AUTH_HIBP_ENABLED="true"
check "status warns when an enabled check cannot reach the API" "1" \
    "$(hardening_status 2>&1 | grep -c 'passwords are NOT being checked')"
unset -f curl

# --- feature names -------------------------------------------------------------
check "feature list" "signup|password-policy|hibp|captcha|rate-limit" "$(_hardening_feature_list)"
hardening_feature_known bogus; check "unknown feature rejected" "1" "$?"

rm -rf "$T"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
