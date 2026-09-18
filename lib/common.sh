#!/usr/bin/env bash
# lib/common.sh - logging, error handling and shared helpers.
# shellcheck shell=bash

SO_INSTALLER_VERSION="1.0.0"

# ---------------------------------------------------------------------------
# Colours (disabled when not a TTY, when NO_COLOR is set, or when piped)
# ---------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
fi

SO_LOG_FILE="${SO_LOG_FILE:-}"
SO_ASSUME_YES="${SO_ASSUME_YES:-false}"
SO_CURRENT_PHASE=""

# Symbols. Fall back to ASCII on terminals that cannot render UTF-8.
if [[ "${LC_ALL:-}${LANG:-}" == *[Uu][Tt][Ff]* ]]; then
    SYM_OK="✓"; SYM_FAIL="✗"; SYM_ARROW="→"
else
    SYM_OK="[ok]"; SYM_FAIL="[x]"; SYM_ARROW="->"
fi

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

# Append a line to the log file, without colour codes.
_log_to_file() {
    [[ -n "$SO_LOG_FILE" ]] || return 0
    local dir
    dir="$(dirname "$SO_LOG_FILE")"
    [[ -d "$dir" ]] || mkdir -p "$dir" 2>/dev/null || return 0
    # 2>/dev/null comes first on purpose: redirections are applied left to
    # right, so with the append first its own "Permission denied" would be
    # written to the terminal before stderr had been silenced. Logging is
    # best-effort - a log that cannot be written must stay quiet about it.
    printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" 2>/dev/null >>"$SO_LOG_FILE" || true
}

log_info()  { printf '%s[INFO]%s  %s\n' "$C_BLUE"   "$C_RESET" "$*";     _log_to_file "[INFO]  $*"; }
log_ok()    { printf '%s[OK]%s    %s\n' "$C_GREEN"  "$C_RESET" "$*";     _log_to_file "[OK]    $*"; }
log_warn()  { printf '%s[WARN]%s  %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; _log_to_file "[WARN]  $*"; }
log_error() { printf '%s[ERROR]%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; _log_to_file "[ERROR] $*"; }

log_debug() {
    _log_to_file "[DEBUG] $*"
    [[ "${SO_DEBUG:-false}" == "true" ]] || return 0
    printf '%s[DEBUG] %s%s\n' "$C_DIM" "$*" "$C_RESET" >&2
}

# A named failure boundary. Every major phase opens one so that a failure can
# report which phase died rather than only a line number.
phase_begin() {
    SO_CURRENT_PHASE="$1"
    printf '\n%s%s %s%s\n' "$C_BOLD$C_CYAN" "$SYM_ARROW" "$1" "$C_RESET"
    _log_to_file "=== PHASE BEGIN: $1 ==="
}

phase_end() {
    _log_to_file "=== PHASE OK: ${SO_CURRENT_PHASE} ==="
    SO_CURRENT_PHASE=""
}

die() {
    log_error "$*"
    if [[ -n "$SO_CURRENT_PHASE" ]]; then
        log_error "Failed during phase: ${SO_CURRENT_PHASE}"
    fi
    if [[ -n "$SO_LOG_FILE" ]]; then
        printf '\n%sFull log: %s%s\n' "$C_DIM" "$SO_LOG_FILE" "$C_RESET" >&2
    fi
    exit 1
}

banner() {
    printf '%s========================================%s\n' "$C_BOLD" "$C_RESET"
    printf '%s        %s%s\n' "$C_BOLD" "$1" "$C_RESET"
    printf '%s========================================%s\n' "$C_BOLD" "$C_RESET"
}

section() {
    local underline
    underline="$(printf '%*s' "${#1}" '' | tr ' ' '-')"
    printf '\n%s%s%s\n%s\n' "$C_BOLD" "$1" "$C_RESET" "$underline"
}

# Status line used by `sentinel-ops status`, e.g. "PostgreSQL   OK Healthy".
status_line() {
    local label="$1" state="$2" text="$3" colour=""
    case "$state" in
        ok)   colour="$C_GREEN";  text="$SYM_OK $text" ;;
        bad)  colour="$C_RED";    text="$SYM_FAIL $text" ;;
        warn) colour="$C_YELLOW"; text="! $text" ;;
    esac
    printf '%-18s %s%s%s\n' "$label" "$colour" "$text" "$C_RESET"
}

# ---------------------------------------------------------------------------
# Command execution
# ---------------------------------------------------------------------------

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# Run a command, capturing output into the log file. On failure the tail of the
# output is shown so the operator sees the real error, not just an exit code.
run_logged() {
    local desc="$1"; shift
    local out rc=0
    log_debug "exec: $*"
    out="$("$@" 2>&1)" || rc=$?
    if [[ -n "$SO_LOG_FILE" ]]; then
        printf '%s\n' "$out" 2>/dev/null >>"$SO_LOG_FILE" || true
    fi
    if (( rc != 0 )); then
        log_error "$desc failed (exit $rc)"
        printf '%s\n' "$out" | tail -n 30 >&2
        return "$rc"
    fi
    return 0
}

# Retry a command with a fixed delay: retry <attempts> <delay> <cmd...>
retry() {
    local attempts="$1" delay="$2"; shift 2
    local n=1
    while true; do
        if "$@"; then return 0; fi
        if (( n >= attempts )); then return 1; fi
        log_debug "attempt ${n}/${attempts} failed, retrying in ${delay}s"
        sleep "$delay"
        n=$(( n + 1 ))
    done
}

# Poll until a predicate succeeds: wait_for <timeout> <interval> <cmd...>
wait_for() {
    local timeout="$1" interval="$2"; shift 2
    local waited=0
    while (( waited < timeout )); do
        if "$@" >/dev/null 2>&1; then return 0; fi
        sleep "$interval"
        waited=$(( waited + interval ))
    done
    return 1
}

# ---------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------

# prompt_default <variable-name> <question> <default>
# Under --yes or without a TTY the default is taken silently, which keeps the
# whole installer usable from CI.
prompt_default() {
    local __var="$1" question="$2" default="$3" answer=""
    if [[ "$SO_ASSUME_YES" == "true" || ! -t 0 ]]; then
        printf '%s\n  [%s] (auto)\n' "$question" "$default"
        printf -v "$__var" '%s' "$default"
        return 0
    fi
    printf '%s\n  [%s]: ' "$question" "$default"
    IFS= read -r answer || answer=""
    [[ -z "$answer" ]] && answer="$default"
    printf -v "$__var" '%s' "$answer"
}

# prompt_secret <variable-name> <question> [existing-value]
# Like prompt_default, but the answer is never echoed to the terminal and the
# caller must never pass it to run_logged or anything else that writes to
# SO_LOG_FILE. Under --yes or without a TTY, the existing value (if any) is
# kept rather than asked for, so a resumed non-interactive run does not clear
# a secret that was entered in an earlier interactive run.
prompt_secret() {
    local __var="$1" question="$2" existing="${3:-}" answer=""
    if [[ "$SO_ASSUME_YES" == "true" || ! -t 0 ]]; then
        printf '%s\n  [%s]\n' "$question" "$([[ -n "$existing" ]] && printf 'kept' || printf 'not set')"
        printf -v "$__var" '%s' "$existing"
        return 0
    fi
    printf '%s%s: ' "$question" "$([[ -n "$existing" ]] && printf ' [leave blank to keep the existing value]' || printf '')"
    IFS= read -r -s answer || answer=""
    printf '\n'
    [[ -z "$answer" ]] && answer="$existing"
    printf -v "$__var" '%s' "$answer"
}

# confirm <question> [default y|n]
confirm() {
    local question="$1" default="${2:-y}" answer="" hint
    if [[ "$default" == "y" ]]; then hint="Y/n"; else hint="y/N"; fi
    if [[ "$SO_ASSUME_YES" == "true" || ! -t 0 ]]; then
        [[ "$default" == "y" ]]
        return $?
    fi
    printf '%s [%s]: ' "$question" "$hint"
    IFS= read -r answer || answer=""
    [[ -z "$answer" ]] && answer="$default"
    [[ "$answer" =~ ^[Yy] ]]
}

# ---------------------------------------------------------------------------
# Misc helpers
# ---------------------------------------------------------------------------

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "This operation must run as root (or via sudo)."
        log_error "Try: sudo sentinel-ops $*"
        exit 1
    fi
}

# Read KEY=VALUE from an env-style file *without* sourcing it. Sourcing would
# execute any shell metacharacters that appear in a generated password.
env_get() {
    local file="$1" key="$2" line value
    [[ -f "$file" ]] || return 1
    line="$(grep -E "^[[:space:]]*${key}=" "$file" | tail -n 1)" || return 1
    [[ -n "$line" ]] || return 1
    value="${line#*=}"
    value="${value%$'\r'}"
    # Strip one layer of surrounding quotes if present.
    if [[ ${#value} -ge 2 && "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
        value="${value:1:${#value}-2}"
    elif [[ ${#value} -ge 2 && "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
        value="${value:1:${#value}-2}"
    fi
    printf '%s' "$value"
}

# Write (or replace) KEY=VALUE in an env-style file, preserving every other
# line. This is how the installer edits Supabase's .env without rewriting it.
env_set() {
    local file="$1" key="$2" value="$3" tmp
    [[ -f "$file" ]] || touch "$file"
    tmp="$(mktemp)"
    # awk rather than sed, so slashes and ampersands in the value stay literal.
    #
    # The value is passed through the environment and read via ENVIRON rather
    # than with `awk -v`: -v expands backslash escapes, which silently corrupts
    # any generated password containing a backslash.
    SO_ENV_VALUE="$value" awk -v k="$key" '
        BEGIN { v = ENVIRON["SO_ENV_VALUE"]; done = 0 }
        $0 ~ "^[[:space:]]*" k "=" { if (!done) { print k "=" v; done = 1 } ; next }
        { print }
        END { if (!done) print k "=" v }
    ' "$file" >"$tmp"
    cat "$tmp" >"$file"
    rm -f "$tmp"
}

# Mask a secret for display: keep the first and last four characters.
mask_secret() {
    local s="$1"
    if (( ${#s} <= 12 )); then
        printf '********'
    else
        printf '%s...%s' "${s:0:4}" "${s: -4}"
    fi
}

random_token() {
    local bytes="${1:-32}"
    openssl rand -hex "$bytes" 2>/dev/null || head -c "$bytes" /dev/urandom | od -An -tx1 | tr -d ' \n'
}

timestamp() { date '+%Y-%m-%d-%H%M%S'; }

strip_trailing_slash() { printf '%s' "${1%/}"; }

# True when something is already listening on this port. Checked against
# 127.0.0.1 regardless of the actual bind address: a listener on 0.0.0.0 (as
# Supabase's own gateway and pooler always are) still accepts a loopback
# connection, so this one check catches both.
port_in_use() {
    local port="$1"
    if (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
        exec 3>&- 2>/dev/null || true
        return 0
    fi
    return 1
}

# Extract the hostname from a URL (no scheme, no path, no port).
url_host() {
    local url="$1"
    url="${url#*://}"
    url="${url%%/*}"
    url="${url%%:*}"
    printf '%s' "$url"
}
