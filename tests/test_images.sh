#!/usr/bin/env bash
# Exercise which Docker images cleanup removes and which it keeps.
#
# docker is replaced with a shell function over a fixture of images and
# containers, so nothing here needs a Docker daemon.
set -uo pipefail

ROOT="${1:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/frontend.sh"
source "${ROOT}/lib/images.sh"

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
LOG="${T}/docker.log"
APP_IMAGE_NAME="sentinel-ops"; SO_LOG_FILE=""

# --- Fixture -----------------------------------------------------------------------
# IMAGES: "repo:tag id" per line, mirrored to a file because rmi runs in a
# command substitution. IN_USE: image ids containers use.
IMAGES=""; IMAGES_FILE="${T}/images"; IN_USE=""; DANGLING=""; WANTED=""; RMI_FAIL=""
declare -A STATE=()
state_get() { printf '%s' "${STATE[$1]:-${2:-}}"; }
supabase_compose() { [[ "$1 $2" == "config --images" ]] && printf '%s\n' "$WANTED"; }

docker() {
    local IMAGES; IMAGES="$(cat "$IMAGES_FILE")"
    printf '%s\n' "$*" >>"$LOG"
    case "$1" in
        ps)      [[ -n "$IN_USE" ]] && printf 'c1\n' ;;
        inspect) printf '%s\n' "$IN_USE" ;;
        image)
            case "$2" in
                inspect) awk -v r="$5" '$1 == r { print $2 }' <<<"$IMAGES" ;;
                prune)   : ;;
            esac
            ;;
        images)
            if [[ " $* " == *" dangling=true "* ]]; then
                printf '%s' "$DANGLING"
            else
                local repo="${*: -1}"
                awk -v r="$repo" '{ ref = $1; sub(/:[^:\/]*$/, "", ref); if (ref == r) print }' <<<"$IMAGES"
            fi
            ;;
        rmi)
            grep -qxF -- "$2" <<<"$RMI_FAIL" && return 1
            awk -v r="$2" '$1 != r' <<<"$IMAGES" >"$IMAGES_FILE"
            ;;
        builder) : ;;
        system)  printf 'Images|12.3GB|8.1GB (65%%)\nContainers|1GB|0B\n' ;;
    esac
    return 0
}

removed() { grep '^rmi ' "$LOG" | cut -d' ' -f2 | sort | tr '\n' ' ' | sed 's/ $//'; }
run() { : >"$LOG"; printf '%s
' "$IMAGES" >"$IMAGES_FILE"; "$@" >/dev/null 2>&1; IMAGES="$(cat "$IMAGES_FILE")"; }

# --- Application images ----------------------------------------------------------------
IMAGES="sentinel-ops:latest sha256:eee
sentinel-ops:eee5555 sha256:eee
sentinel-ops:ddd4444 sha256:ddd
sentinel-ops:ccc3333 sha256:ccc
sentinel-ops:bbb2222 sha256:bbb
sentinel-ops:aaa1111 sha256:aaa
sentinel-opsextra:x sha256:xxx
zoraxy/zoraxy:latest sha256:zzz"
STATE=([APP_IMAGE]="sentinel-ops:eee5555" [PREVIOUS_APP_IMAGE]="sentinel-ops:ddd4444")
run images_prune_app
check "old builds removed, current/previous/latest kept" \
    "sentinel-ops:aaa1111 sentinel-ops:bbb2222 sentinel-ops:ccc3333" "$(removed)"
check "never forced" "0" "$(grep -c '^rmi -f' "$LOG")"
check "a similarly named repository is untouched" "1" "$(grep -c '^sentinel-opsextra:x' <<<"$IMAGES")"
check "other workloads' images are untouched" "1" "$(grep -c '^zoraxy/zoraxy:latest' <<<"$IMAGES")"

# A second run finds nothing more.
run images_prune_app
check "second run removes nothing" "" "$(removed)"

# An image a container still uses (a leftover staging container) stays.
IMAGES+=$'\nsentinel-ops:fff6666 sha256:fff'
IN_USE="sha256:fff"
run images_prune_app
check "image in use by a container is kept" "" "$(removed)"
IN_USE=""

# Another tag of the deployed image is the same image: untagging it frees
# nothing, so leave it.
IMAGES+=$'\nsentinel-ops:alias sha256:eee'
run images_prune_app
check "alias of the deployed image is kept" "sentinel-ops:fff6666" "$(removed)"

# A refused removal is a warning, not a failure.
IMAGES+=$'\nsentinel-ops:ggg7777 sha256:ggg'
RMI_FAIL="sentinel-ops:ggg7777"
: >"$LOG"; printf '%s
' "$IMAGES" >"$IMAGES_FILE"
images_prune_app >/dev/null 2>&1
check "refused rmi does not fail cleanup" "0" "$?"
RMI_FAIL=""

# Untagged builds are pruned by our label only.
DANGLING=$'sha256:old1\n'
run images_prune_app
check "dangling builds pruned by label" "1" \
    "$(grep -c "^image prune -f --filter label=${APP_IMAGE_LABEL}$" "$LOG")"
check "never a label-less prune" "0" "$(grep -c '^image prune -f$' "$LOG")"
DANGLING=""

# Dry run lists, removes nothing.
IMAGES+=$'\nsentinel-ops:hhh8888 sha256:hhh'
SO_IMAGES_DRY_RUN="true"
: >"$LOG"; printf '%s
' "$IMAGES" >"$IMAGES_FILE"
out="$(images_prune_app 2>&1)"
check "dry run removes nothing" "" "$(removed)"
check "dry run lists the candidate" "1" "$(grep -c 'would remove sentinel-ops:hhh8888' <<<"$out")"
SO_IMAGES_DRY_RUN="false"

# --- Supabase images ---------------------------------------------------------------------
IMAGES="supabase/storage-api:v1.81.0 sha256:s81
supabase/storage-api:v1.80.0 sha256:s80
supabase/storage-api:v1.79.0 sha256:s79
supabase/gotrue:v2.180.0 sha256:g180
supabase/gotrue:v2.170.0 sha256:g170
postgrest/postgrest:v13.0.0 sha256:p13
envoyproxy/envoy:v1.39.1 sha256:e139
envoyproxy/envoy:v1.38.0 sha256:e138
supabase/logflare:1.0.0 sha256:l1
nginx:1.27-alpine sha256:ngx
registry.local:5000/supabase/studio:new sha256:st2
registry.local:5000/supabase/studio:old sha256:st1"
WANTED="supabase/storage-api:v1.81.0
supabase/gotrue:v2.180.0
postgrest/postgrest:v13.0.0
envoyproxy/envoy:v1.39.1
registry.local:5000/supabase/studio:new"
IN_USE="sha256:e138"
run images_prune_supabase
check "superseded tags of compose repositories removed" \
    "registry.local:5000/supabase/studio:old supabase/gotrue:v2.170.0 supabase/storage-api:v1.79.0 supabase/storage-api:v1.80.0" \
    "$(removed)"
check "an old tag still running is kept" "1" "$(grep -c '^envoyproxy/envoy:v1.38.0' <<<"$IMAGES")"
check "repositories outside the config are untouched" "2" "$(grep -cE '^(supabase/logflare|nginx):' <<<"$IMAGES")"
IN_USE=""

WANTED=""
run images_prune_supabase
check "no compose config, nothing removed" "" "$(removed)"

check "repo of a plain ref"        "supabase/gotrue"                    "$(_images_repo_of supabase/gotrue:v2)"
check "repo of a registry:port ref" "registry.local:5000/supabase/studio" "$(_images_repo_of registry.local:5000/supabase/studio:new)"
check "repo of an untagged ref"    "registry.local:5000/x"              "$(_images_repo_of registry.local:5000/x)"

# --- Build cache --------------------------------------------------------------------------
run images_prune_build_cache
check "build cache pruned by age" "1" "$(grep -c '^builder prune -f --filter until=168h$' "$LOG")"
IMAGE_BUILD_CACHE_MAX_AGE="1 week; rm -rf /"
run images_prune_build_cache
check "bad age falls back to 168h" "1" "$(grep -c '^builder prune -f --filter until=168h$' "$LOG")"
IMAGE_BUILD_CACHE_MAX_AGE="24h"
run images_prune_build_cache
check "custom age passed through" "1" "$(grep -c '^builder prune -f --filter until=24h$' "$LOG")"
IMAGE_BUILD_CACHE_MAX_AGE="168h"

# --- The switch -------------------------------------------------------------------------------
IMAGES="sentinel-ops:old sha256:old"
STATE=([APP_IMAGE]="sentinel-ops:new")
IMAGE_CLEANUP_ENABLED="false"
run images_cleanup_after_app_update
check "disabled: nothing removed" "" "$(removed)"
check "disabled: no build cache prune" "0" "$(grep -c '^builder' "$LOG")"
IMAGE_CLEANUP_ENABLED="true"
run images_cleanup_after_app_update
check "enabled: old build removed" "sentinel-ops:old" "$(removed)"

# --- Disk usage ------------------------------------------------------------------------------
check "image usage from system df" "12.3GB, 8.1GB (65%) reclaimable" "$(images_disk_usage)"

rm -rf "$T"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
