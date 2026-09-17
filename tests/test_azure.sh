#!/usr/bin/env bash
# Exercise the Azure AD docker-compose.yml patch: a pure text transform, so it
# is tested the same way as the nuke path guards and the secret-placeholder
# logic - against a fixture, without Docker or a live Supabase stack.
set -uo pipefail

ROOT="${1:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/azure.sh"

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
API_EXTERNAL_URL="http://localhost:8000"

# --- a fixture mirroring upstream's actual auth-service environment block --
_write_fixture() {
    cat >"${T}/docker-compose.yml" <<'EOF'
  auth:
    container_name: supabase-auth
    environment:
      GOTRUE_EXTERNAL_EMAIL_ENABLED: ${ENABLE_EMAIL_SIGNUP}

      # GOTRUE_EXTERNAL_GOOGLE_ENABLED: ${GOOGLE_ENABLED}
      # GOTRUE_EXTERNAL_GOOGLE_CLIENT_ID: ${GOOGLE_CLIENT_ID}

      # GOTRUE_EXTERNAL_AZURE_ENABLED: ${AZURE_ENABLED}
      # GOTRUE_EXTERNAL_AZURE_CLIENT_ID: ${AZURE_CLIENT_ID}
      # GOTRUE_EXTERNAL_AZURE_SECRET: ${AZURE_SECRET}
      # GOTRUE_EXTERNAL_AZURE_REDIRECT_URI: ${API_EXTERNAL_URL}/callback

  rest:
    container_name: supabase-rest
EOF
}

# --- disabled: the compose file must be left untouched ---------------------
_write_fixture
ORIG="$(cat "${T}/docker-compose.yml")"
ENABLE_AZURE_AD="false"
azure_patch_compose >/dev/null 2>&1
check "disabled leaves compose untouched" "$ORIG" "$(cat "${T}/docker-compose.yml")"

# --- enabled: the four lines are uncommented, one new line is inserted -----
_write_fixture
ENABLE_AZURE_AD="true"
azure_patch_compose >/dev/null 2>&1

check "ENABLED uncommented" \
    "1" "$(grep -c '^      GOTRUE_EXTERNAL_AZURE_ENABLED: \${AZURE_ENABLED}$' "${T}/docker-compose.yml")"
check "CLIENT_ID uncommented" \
    "1" "$(grep -c '^      GOTRUE_EXTERNAL_AZURE_CLIENT_ID: \${AZURE_CLIENT_ID}$' "${T}/docker-compose.yml")"
check "SECRET uncommented" \
    "1" "$(grep -c '^      GOTRUE_EXTERNAL_AZURE_SECRET: \${AZURE_SECRET}$' "${T}/docker-compose.yml")"
check "REDIRECT_URI uncommented" \
    "1" "$(grep -c '^      GOTRUE_EXTERNAL_AZURE_REDIRECT_URI: \${API_EXTERNAL_URL}/callback$' "${T}/docker-compose.yml")"
check "URL line inserted once" \
    "1" "$(grep -c 'GOTRUE_EXTERNAL_AZURE_URL: \${AZURE_URL:-}' "${T}/docker-compose.yml")"
check "unrelated GOOGLE lines untouched" \
    "1" "$(grep -c '^      # GOTRUE_EXTERNAL_GOOGLE_ENABLED:' "${T}/docker-compose.yml")"
check "sibling rest service still present" \
    "1" "$(grep -c '^  rest:$' "${T}/docker-compose.yml")"

# --- idempotency: a second run changes nothing further ----------------------
AFTER_FIRST="$(cat "${T}/docker-compose.yml")"
azure_patch_compose >/dev/null 2>&1
check "second run is idempotent" "$AFTER_FIRST" "$(cat "${T}/docker-compose.yml")"

# --- an upstream compose file with no Azure wiring at all warns, not fails --
cat >"${T}/docker-compose.yml" <<'EOF'
  auth:
    environment:
      GOTRUE_EXTERNAL_EMAIL_ENABLED: ${ENABLE_EMAIL_SIGNUP}
EOF
ENABLE_AZURE_AD="true"
azure_patch_compose >/dev/null 2>&1
check "missing wiring returns non-zero" "1" "$?"

# --- redirect URI helper ----------------------------------------------------
API_EXTERNAL_URL="https://supabase.example.com"
check "redirect uri" "https://supabase.example.com/callback" "$(_azure_redirect_uri)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
rm -rf "$T"
[[ $fail -eq 0 ]]
