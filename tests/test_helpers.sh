#!/usr/bin/env bash
# Exercise the pure helper functions that the deployment logic relies on.
set -uo pipefail

ROOT="${1:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/database.sh" 2>/dev/null || true

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
ENVF="${T}/.env"

# --- A realistic supabase/.env, including values with awkward characters ----
cat >"$ENVF" <<'EOF'
############
# Secrets
############
POSTGRES_PASSWORD=p@ss/w0rd+with&special=chars
JWT_SECRET="quoted-secret-value"
ANON_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.abc.def

############
# API Proxy
############
KONG_HTTP_PORT=8000
SITE_URL=http://localhost:3000
# A commented line mentioning SITE_URL=http://decoy
EMPTY_VALUE=
EOF

check "env_get plain"            "p@ss/w0rd+with&special=chars" "$(env_get "$ENVF" POSTGRES_PASSWORD)"
check "env_get strips quotes"    "quoted-secret-value"          "$(env_get "$ENVF" JWT_SECRET)"
check "env_get jwt"              "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.abc.def" "$(env_get "$ENVF" ANON_KEY)"
check "env_get port"             "8000"                         "$(env_get "$ENVF" KONG_HTTP_PORT)"
check "env_get empty value"      ""                             "$(env_get "$ENVF" EMPTY_VALUE)"
env_get "$ENVF" NO_SUCH_KEY >/dev/null 2>&1
check "env_get missing -> fail"  "1"                            "$?"

# --- env_set must replace in place and preserve everything else ------------
before_lines="$(wc -l <"$ENVF")"
env_set "$ENVF" SITE_URL "https://app.example.com"
check "env_set replaced"         "https://app.example.com"      "$(env_get "$ENVF" SITE_URL)"
check "env_set kept line count"  "$before_lines"                "$(wc -l <"$ENVF")"
check "env_set kept other keys"  "p@ss/w0rd+with&special=chars" "$(env_get "$ENVF" POSTGRES_PASSWORD)"
check "env_set kept comments"    "7"                            "$(grep -c '^#' "$ENVF" | tr -d ' ')"
check "comment not clobbered"    "1"                            "$(grep -c 'decoy' "$ENVF" | tr -d ' ')"

# Slashes and ampersands in the *value* must survive (sed would mangle these).
env_set "$ENVF" POSTGRES_PASSWORD 'a/b&c\d'
check "env_set special chars"    'a/b&c\d'                      "$(env_get "$ENVF" POSTGRES_PASSWORD)"

# Appending a brand-new key.
env_set "$ENVF" BRAND_NEW_KEY "hello"
check "env_set appends new"      "hello"                        "$(env_get "$ENVF" BRAND_NEW_KEY)"
check "append kept old"          "8000"                         "$(env_get "$ENVF" KONG_HTTP_PORT)"

# Idempotency: setting the same value twice must not duplicate the key.
env_set "$ENVF" BRAND_NEW_KEY "hello"
check "env_set idempotent"       "1"                            "$(grep -c '^BRAND_NEW_KEY=' "$ENVF" | tr -d ' ')"

# A key that is a prefix of another must not be confused with it.
env_set "$ENVF" SITE "short"
check "prefix key distinct"      "https://app.example.com"      "$(env_get "$ENVF" SITE_URL)"
check "prefix key set"           "short"                        "$(env_get "$ENVF" SITE)"

# --- URL helpers -----------------------------------------------------------
check "url_host https"           "supabase.example.com"         "$(url_host https://supabase.example.com/rest/v1)"
check "url_host with port"       "localhost"                    "$(url_host http://localhost:8000)"
check "url_host bare"            "example.com"                  "$(url_host example.com)"
check "strip_trailing_slash"     "https://a.com"                "$(strip_trailing_slash https://a.com/)"

# --- secret masking --------------------------------------------------------
check "mask long"                "eyJh...9xyz"                  "$(mask_secret 'eyJhbGciOiJIUzI1NiL9xyz')"
check "mask short"               "********"                     "$(mask_secret 'short')"

# --- migration filename parsing -------------------------------------------
check "version parse"            "20240101120000"               "$(_migration_version 20240101120000_add_users.sql)"
check "name parse"               "add_users"                    "$(_migration_name 20240101120000_add_users.sql)"
check "version no suffix"        "20240101120000"               "$(_migration_version 20240101120000.sql)"
check "sql quote escapes"        "it''s"                        "$(_sql_quote "it's")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
rm -rf "$T"
[[ $fail -eq 0 ]]
