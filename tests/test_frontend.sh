#!/usr/bin/env bash
# Exercise the image build's DNS preflight and its network-error retry.
#
# docker and getent are replaced with shell functions, so nothing here needs a
# Docker daemon or network access.
set -uo pipefail

ROOT="${1:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/frontend.sh"

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
APP_DIR="$T"; APP_PORT=3000; APP_IMAGE_NAME="sentinel-ops"; SO_LOG_FILE=""
SO_BUILD_RETRY_DELAY=0
repo_short_commit() { printf 'abc1234'; }
frontend_provision_build_files() { :; }
sleep() { :; }

# --- Failure classification ----------------------------------------------------
DNS_ERR='failed to fetch anonymous token: Get "https://auth.docker.io/token": dial tcp: lookup auth.docker.io on 127.0.0.53:53: read udp 127.0.0.1:59134->127.0.0.53:53: i/o timeout'
BUILD_ERR='ERROR: failed to solve: process "/bin/sh -c npm run build" did not complete successfully: exit code: 1'

classify() { is_network_error "$1" && printf 'network' || printf 'other'; }
check "DNS timeout is a network error"       "network" "$(classify "$DNS_ERR")"
check "no such host is a network error"      "network" "$(classify 'dial tcp: lookup registry-1.docker.io: no such host')"
check "compile failure is not a network error" "other" "$(classify "$BUILD_ERR")"

# --- Stubs ----------------------------------------------------------------------
# docker build fails with the output in BUILD_OUTPUTS[n] for the n-th call, and
# succeeds once the list runs out.
BUILD_OUTPUTS=(); BUILD_CALLS_FILE="${T}/calls"; DOCKER_PROXY=""; DNS_OK=1
docker() {
    case "$1" in
        info)  printf '%s' "$DOCKER_PROXY" ;;
        build)
            local n; n="$(cat "$BUILD_CALLS_FILE" 2>/dev/null || echo 0)"
            printf '%s' "$((n + 1))" >"$BUILD_CALLS_FILE"
            if (( n < ${#BUILD_OUTPUTS[@]} )); then printf '%s\n' "${BUILD_OUTPUTS[$n]}"; return 1; fi
            ;;
    esac
}
getent() { (( DNS_OK )); }
wait_for() { "${@:3}"; }

build() {
    rm -f "$BUILD_CALLS_FILE"
    if frontend_build_image >/dev/null 2>&1; then r=ok; else r=failed; fi
    printf '%s/%s' "$r" "$(cat "$BUILD_CALLS_FILE" 2>/dev/null || echo 0)"
}

# --- Preflight -------------------------------------------------------------------
DNS_OK=1; BUILD_OUTPUTS=()
check "clean build: one attempt"                   "ok/1"     "$(build)"

DNS_OK=0
check "unresolvable Docker Hub stops before build" "failed/0" "$(build)"

DNS_OK=0; DOCKER_PROXY="http://proxy:3128"
check "preflight skipped behind a Docker proxy"    "ok/1"     "$(build)"
DOCKER_PROXY=""; DNS_OK=1

# --- Retry -----------------------------------------------------------------------
BUILD_OUTPUTS=("$DNS_ERR")
check "network failure is retried, then succeeds"  "ok/2"     "$(build)"

BUILD_OUTPUTS=("$DNS_ERR" "$DNS_ERR" "$DNS_ERR")
check "persistent network failure gives up after 3" "failed/3" "$(build)"

BUILD_OUTPUTS=("$BUILD_ERR")
check "real build error is not retried"            "failed/1" "$(build)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
rm -rf "$T"
[[ $fail -eq 0 ]]
