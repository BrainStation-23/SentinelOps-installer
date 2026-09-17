#!/usr/bin/env bash
# Verify secret generation: JWT signing and the Logflare encryption key.
#
# The JWTs matter: on the fallback install path the installer signs the anon
# and service_role keys itself, and a malformed token means every API request
# from the frontend is rejected.
set -uo pipefail

ROOT="${1:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/config.sh"
source "${ROOT}/lib/supabase.sh"

# Point the libraries at a scratch installation. This must happen AFTER the
# sources: config.sh declares the path variables and would blank them again.
TMPROOT="$(mktemp -d)"
config_set_paths "$TMPROOT"
mkdir -p "$SUPABASE_DIR"

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
ok()  { check "$1" "0" "$2"; }
nok() { check "$1" "1" "$2"; }

# --- base64url -------------------------------------------------------------
# Must be unpadded and use the URL-safe alphabet.
enc="$(printf '{"alg":"HS256","typ":"JWT"}' | _b64url)"
check "b64url header" "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9" "$enc"
check "b64url unpadded" "0" "$(printf '%s' "$enc" | grep -c '=' || true)"

# --- JWT structure ---------------------------------------------------------
token="$(_sign_jwt "test-secret" "anon" 1700000000 2000000000)"
check "jwt has three parts" "3" "$(printf '%s' "$token" | awk -F. '{print NF}')"

# Decode the payload, restoring the base64 padding that base64url strips.
# Note: the padding must only be added when it is actually needed - a single
# stray '=' makes openssl silently drop the final bytes of the payload.
payload_b64="$(printf '%s' "$token" | cut -d. -f2)"
pad=$(( (4 - ${#payload_b64} % 4) % 4 ))
padded="$payload_b64"
while (( pad-- > 0 )); do padded="${padded}="; done
payload="$(printf '%s' "$padded" | tr '_-' '/+' | openssl base64 -d -A 2>/dev/null)"
check "jwt role claim"  "1" "$(printf '%s' "$payload" | grep -c '"role":"anon"')"
check "jwt issuer"      "1" "$(printf '%s' "$payload" | grep -c '"iss":"supabase"')"
check "jwt exp"         "1" "$(printf '%s' "$payload" | grep -c '"exp":2000000000')"

# Signature must actually verify against the secret.
expected_sig="$(printf '%s.%s' "$(printf '%s' "$token" | cut -d. -f1)" "$payload_b64" \
    | openssl dgst -sha256 -hmac "test-secret" -binary | _b64url)"
check "jwt signature verifies" "$expected_sig" "$(printf '%s' "$token" | cut -d. -f3)"

# A different secret must produce a different signature.
other="$(_sign_jwt "other-secret" "anon" 1700000000 2000000000)"
if [[ "$token" != "$other" ]]; then
    printf 'PASS  jwt differs by secret\n'; pass=$((pass+1))
else
    printf 'FAIL  jwt differs by secret\n'; fail=$((fail+1))
fi

# anon and service_role must differ.
svc="$(_sign_jwt "test-secret" "service_role" 1700000000 2000000000)"
if [[ "$token" != "$svc" ]]; then
    printf 'PASS  anon differs from service_role\n'; pass=$((pass+1))
else
    printf 'FAIL  anon differs from service_role\n'; fail=$((fail+1))
fi

# --- random_token ----------------------------------------------------------
t1="$(random_token 32)"; t2="$(random_token 32)"
check "random_token length" "64" "${#t1}"
if [[ "$t1" != "$t2" ]]; then
    printf 'PASS  random_token is random\n'; pass=$((pass+1))
else
    printf 'FAIL  random_token repeated\n'; fail=$((fail+1))
fi

# --- Logflare encryption key ----------------------------------------------
# Upstream requires LOGFLARE_DB_ENCRYPTION_KEY to be base64. openssl emits
# padding and the +/ alphabet, all of which must survive a round trip through
# the env file - a corrupted key makes Logflare unable to read its own columns.
ENVF="${SUPABASE_DIR}/.env"
: >"$ENVF"
key="$(openssl rand -base64 32)"
env_set "$ENVF" LOGFLARE_DB_ENCRYPTION_KEY "$key"
check "base64 key round trips" "$key" "$(env_get "$ENVF" LOGFLARE_DB_ENCRYPTION_KEY)"
check "base64 key is 44 chars" "44" "${#key}"

# A value containing '=' must not be truncated at the first separator.
env_set "$ENVF" PADDED "abc=def=="
check "value with = preserved" "abc=def==" "$(env_get "$ENVF" PADDED)"

# --- Placeholder detection -------------------------------------------------
#
# These are the exact values Supabase ships in docker/.env.example. Every one
# must be replaced: a deployment that keeps any of them is compromised out of
# the box. VAULT_ENC_KEY, DASHBOARD_PASSWORD and SECRET_KEY_BASE carry no
# obvious placeholder marker, which is precisely why this table exists rather
# than a "looks secret-ish" substring heuristic.
_check_placeholder() {
    local desc="$1" value="$2"
    if _is_placeholder "$value"; then
        printf 'PASS  %s\n' "$desc"; pass=$((pass+1))
    else
        printf 'FAIL  %s\n        upstream value would be kept: [%s]\n' "$desc" "$value"
        fail=$((fail+1))
    fi
}
_check_not_placeholder() {
    local desc="$1" value="$2"
    if _is_placeholder "$value"; then
        printf 'FAIL  %s\n        generated value treated as placeholder: [%s]\n' "$desc" "$value"
        fail=$((fail+1))
    else
        printf 'PASS  %s\n' "$desc"; pass=$((pass+1))
    fi
}

_check_placeholder "placeholder JWT_SECRET"         'your-super-secret-jwt-token-with-at-least-32-characters-long'
_check_placeholder "placeholder POSTGRES_PASSWORD"  'your-super-secret-and-long-postgres-password'
_check_placeholder "placeholder POOLER_TENANT_ID"   'your-tenant-id'
_check_placeholder "placeholder LOGFLARE token"     'your-super-secret-and-long-logflare-key-public'
_check_placeholder "placeholder VAULT_ENC_KEY"      'your-32-character-encryption-key'
_check_placeholder "placeholder DASHBOARD_PASSWORD" 'this_password_is_insecure_and_should_be_updated'
_check_placeholder "placeholder SECRET_KEY_BASE"    'UpNVntn3cDxHJpq99YMc1T1AQgQpc8kfYTuRgBiYa15BLrx8etQoXz3gZv1/u2oq'
_check_placeholder "placeholder empty value"        ''
_check_placeholder "placeholder demo ANON_KEY" \
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyAgCiAgICAicm9sZSI6ICJhbm9uIiwKICAgICJpc3MiOiAic3VwYWJhc2UtZGVtbyIsCiAgICAiaWF0IjogMTY0MTc2OTIwMCwKICAgICJleHAiOiAxNzk5NTM1NjAwCn0.dc_X5iR_VP_qT0zsiyj_I_OZ2T9FtRU2BBNWN8Bu4GE'

# A freshly generated secret must NOT be mistaken for a placeholder, or every
# run would rotate it and lock every existing user out.
_check_not_placeholder "generated token kept"    "$(random_token 32)"
_check_not_placeholder "generated b64 key kept"  "$(openssl rand -base64 32)"
_check_not_placeholder "issued anon jwt kept"    "$(_sign_jwt 'test-secret' anon 1700000000 2000000000)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
rm -rf "$TMPROOT"
[[ $fail -eq 0 ]]
