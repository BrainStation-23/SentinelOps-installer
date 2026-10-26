#!/usr/bin/env bash
# Exercise the storage upload-limit overlay, its COMPOSE_FILE registration
# alongside the other overlays, and the Tus-Max-Size / proxy-body probes.
#
# curl is replaced with a shell function, so nothing here needs Docker or a
# live stack.
set -uo pipefail

ROOT="${1:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/supabase.sh"
source "${ROOT}/lib/hardening.sh"
source "${ROOT}/lib/storage.sh"

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
ENV="${T}/.env"
OVERLAY="${T}/${STORAGE_OVERLAY}"

_reset() {
    printf 'COMPOSE_FILE=docker-compose.yml\nJWT_SECRET=x\nANON_KEY=anon-key\n' >"$ENV"
    rm -f "$OVERLAY" "${T}/${HARDENING_OVERLAY}"
    STORAGE_FILE_SIZE_LIMIT="$STORAGE_DEFAULT_FILE_SIZE_LIMIT"
    AUTH_PASSWORD_POLICY="false"; AUTH_HIBP_ENABLED="false"; AUTH_CAPTCHA_ENABLED="false"
    AUTH_RATE_LIMIT_HEADER=""; AUTH_DISABLE_SIGNUP="false"; TURNSTILE_SECRET_KEY=""
}

# --- human_bytes ---------------------------------------------------------------
check "human_bytes 4 GiB"    "4.0 GiB"   "$(human_bytes 4294967296)"
check "human_bytes 50 MiB"   "50.0 MiB"  "$(human_bytes 52428800)"
check "human_bytes 1.5 KiB"  "1.5 KiB"   "$(human_bytes 1536)"
check "human_bytes bytes"    "512 B"     "$(human_bytes 512)"

# --- overlay -------------------------------------------------------------------
_reset
storage_apply_config >/dev/null 2>&1
check "overlay written" "present" "$([[ -f "$OVERLAY" ]] && printf present || printf absent)"
check "overlay registered" "docker-compose.yml:${STORAGE_OVERLAY}" "$(env_get "$ENV" COMPOSE_FILE)"
check "FILE_SIZE_LIMIT is 4 GiB" "1" "$(grep -c "^      FILE_SIZE_LIMIT: '4294967296'$" "$OVERLAY")"
check "UPLOAD_FILE_SIZE_LIMIT is 4 GiB" "1" "$(grep -c "^      UPLOAD_FILE_SIZE_LIMIT: '4294967296'$" "$OVERLAY")"
check "overlay targets the storage service" "1" "$(grep -c '^  storage:$' "$OVERLAY")"
check "overlay is reported registered" "yes" "$(storage_overlay_registered && printf yes || printf no)"

# Idempotent: a second apply changes nothing, so repair does not restart.
before="$(_storage_fingerprint)"
storage_apply_config >/dev/null 2>&1
check "re-apply is a no-op" "$before" "$(_storage_fingerprint)"

# A changed limit rewrites the overlay and changes the fingerprint.
STORAGE_FILE_SIZE_LIMIT="1073741824"
storage_apply_config >/dev/null 2>&1
check "custom limit written" "1" "$(grep -c "^      FILE_SIZE_LIMIT: '1073741824'$" "$OVERLAY")"
check "custom limit changes the fingerprint" "changed" \
    "$([[ "$before" != "$(_storage_fingerprint)" ]] && printf changed || printf same)"

# A hand-edited value that is not a byte count never reaches Compose.
for bad in "4G" "" "0" "-5" "12 34" "0123"; do
    STORAGE_FILE_SIZE_LIMIT="$bad"
    check "bad limit '${bad}' falls back to the default" "4294967296" "$(storage_file_size_limit 2>/dev/null)"
done

# --- COMPOSE_FILE alongside the other overlays ------------------------------------
_reset
env_set "$ENV" COMPOSE_FILE "docker-compose.yml:docker-compose.logs.yml"
storage_apply_config >/dev/null 2>&1
check "logs overlay kept" "docker-compose.yml:docker-compose.logs.yml:${STORAGE_OVERLAY}" "$(env_get "$ENV" COMPOSE_FILE)"

# Hardening moves its overlay to the end; storage keeps its place. Together
# they must settle, or repair would restart services on every run.
AUTH_PASSWORD_POLICY="true"
hardening_apply_config >/dev/null 2>&1
storage_apply_config >/dev/null 2>&1
settled="$(env_get "$ENV" COMPOSE_FILE)"
check "both overlays registered" \
    "docker-compose.yml:docker-compose.logs.yml:${STORAGE_OVERLAY}:${HARDENING_OVERLAY}" "$settled"
for _ in 1 2; do
    hardening_apply_config >/dev/null 2>&1
    storage_apply_config >/dev/null 2>&1
done
check "repeated applies do not reorder" "$settled" "$(env_get "$ENV" COMPOSE_FILE)"

# Hardening switched off removes only its own entry.
AUTH_PASSWORD_POLICY="false"
hardening_apply_config >/dev/null 2>&1
check "hardening off keeps storage" \
    "docker-compose.yml:docker-compose.logs.yml:${STORAGE_OVERLAY}" "$(env_get "$ENV" COMPOSE_FILE)"

# An .env with no COMPOSE_FILE (older upstream) gets the base file first.
_reset
printf 'JWT_SECRET=x\n' >"$ENV"
storage_apply_config >/dev/null 2>&1
check "no COMPOSE_FILE: base file added first" "docker-compose.yml:${STORAGE_OVERLAY}" "$(env_get "$ENV" COMPOSE_FILE)"

# A reset COMPOSE_FILE (the update/repair drift case) is detected and fixed.
_reset
storage_apply_config >/dev/null 2>&1
env_set "$ENV" COMPOSE_FILE "docker-compose.yml"
check "dropped registration is detected" "no" "$(storage_overlay_registered && printf yes || printf no)"
before="$(_storage_fingerprint)"
storage_apply_config >/dev/null 2>&1
check "re-apply restores the registration" "yes" "$(storage_overlay_registered && printf yes || printf no)"
check "and reports a change" "changed" "$([[ "$before" != "$(_storage_fingerprint)" ]] && printf changed || printf same)"

# --- Tus-Max-Size parsing ------------------------------------------------------------
HDRS=$'HTTP/1.1 204 No Content\r\nTus-Resumable: 1.0.0\r\nTus-Version: 1.0.0\r\nTus-Max-Size: 4294967296\r\nTus-Extension: creation\r\n\r\n'
check "parse Tus-Max-Size" "4294967296" "$(_storage_parse_tus_max_size <<<"$HDRS")"
check "parse is case-insensitive" "52428800" "$(_storage_parse_tus_max_size <<<$'HTTP/2 204\r\ntus-max-size: 52428800\r\n')"
_storage_parse_tus_max_size <<<$'HTTP/1.1 401 Unauthorized\r\ncontent-type: text/plain\r\n' >/dev/null
check "no header -> fail" "1" "$?"

# --- Probes (curl stubbed) -------------------------------------------------------------
supabase_kong_port() { printf '8000'; }
CURL_LOG="${T}/curl.log"
CURL_HEADERS=""; CURL_CODE=""; CURL_RC=0
curl() {
    printf '%s\n' "$*" >>"$CURL_LOG"
    if [[ " $* " == *" -X PATCH "* ]]; then
        cat >/dev/null
        printf '%s' "$CURL_CODE"
    else
        printf '%s' "$CURL_HEADERS"
    fi
    return "$CURL_RC"
}

_reset
rm -f "$CURL_LOG"
CURL_HEADERS="$HDRS"
check "upload limit read through the gateway" "4294967296" "$(storage_upload_limit http://localhost:8000/)"
check "OPTIONS on the TUS endpoint" "1" "$(grep -c -- '-X OPTIONS .*http://localhost:8000/storage/v1/upload/resumable$' "$CURL_LOG")"
check "probe sends Tus-Resumable" "1" "$(grep -c 'Tus-Resumable: 1.0.0' "$CURL_LOG")"
check "probe sends the apikey" "1" "$(grep -c 'apikey: anon-key' "$CURL_LOG")"

CURL_RC=7; CURL_HEADERS=""
storage_upload_limit http://localhost:8000 >/dev/null
check "unreachable -> fail" "1" "$?"
CURL_RC=0

# Status: ok at 4 GiB, warn below it, and public URL reported separately.
SUPABASE_PUBLIC_URL="http://localhost:8000"
CURL_HEADERS="$HDRS"
out="$(storage_status 2>&1)"
check "status ok at 4 GiB" "1" "$(grep -c 'Upload limit.*4.0 GiB' <<<"$out")"
check "no public line when it is the gateway" "0" "$(grep -c 'Upload (public)' <<<"$out")"

CURL_HEADERS=$'HTTP/1.1 204\r\nTus-Max-Size: 52428800\r\n'
out="$(storage_status 2>&1)"
check "status warns below the configured limit" "1" "$(grep -c '! 50.0 MiB, expected 4.0 GiB - run: sentinel-ops repair apply' <<<"$out")"

STORAGE_FILE_SIZE_LIMIT="52428800"
out="$(storage_status 2>&1)"
check "a deliberately lower limit is not a warning" "0" "$(grep -c '!' <<<"$out")"
STORAGE_FILE_SIZE_LIMIT="$STORAGE_DEFAULT_FILE_SIZE_LIMIT"

SUPABASE_PUBLIC_URL="https://supabase.example.com"
CURL_HEADERS="$HDRS"
out="$(storage_status 2>&1)"
check "public URL checked too" "1" "$(grep -c 'Upload (public).*4.0 GiB' <<<"$out")"

# Proxy body check: 413 is the proxy, anything else from Storage is fine.
rm -f "$CURL_LOG"
CURL_CODE="413"
check "413 is reported as a proxy limit" "1" "$(storage_proxy_status | grep -c 'refuses a 6 MiB upload chunk (413)')"
check "probe PATCHes a bogus upload" "1" "$(grep -c -- '-X PATCH .*https://supabase.example.com/storage/v1/upload/resumable/sentinel-ops-probe-' "$CURL_LOG")"
CURL_CODE="404"
check "storage's own 404 means the body got through" "1" "$(storage_proxy_status | grep -c 'Accepts a 6 MiB upload chunk')"
CURL_CODE="000"
check "no answer is not a verdict" "1" "$(storage_proxy_status | grep -c 'not reachable from this host')"

# The probe really sends a chunk-sized body.
curl() { local n; n="$(wc -c | tr -d ' ')"; printf '%s' "$n" >"${T}/body"; printf '404'; }
storage_proxy_body_code https://supabase.example.com >/dev/null
check "probe body is 7 MiB" "7340032" "$(cat "${T}/body")"

rm -rf "$T"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
