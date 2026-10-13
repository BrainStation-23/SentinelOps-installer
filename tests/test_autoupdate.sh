#!/usr/bin/env bash
# Exercise the auto-update decision, its systemd unit text and the update lock.
#
# The decision is the whole promise of the feature - an update runs when the
# branch has moved, and only then - so every outcome is asserted here with no
# git, network or systemd involved. The cycle itself (ls-remote, then
# cmd_update_app) needs a live installation and is not run.
set -uo pipefail

ROOT="${1:-$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${ROOT}/lib/common.sh"
source "${ROOT}/lib/config.sh"
source "${ROOT}/lib/selfinstall.sh"
source "${ROOT}/lib/commands/update.sh"
source "${ROOT}/lib/commands/autoupdate.sh"

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
config_set_paths "${T}/root"

A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
C="cccccccccccccccccccccccccccccccccccccccc"

# --- The decision -----------------------------------------------------------
check "same commit: nothing to do"            "current"    "$(_autoupdate_decide "$A" "$A" "")"
check "branch moved: update"                  "update"     "$(_autoupdate_decide "$B" "$A" "")"
check "unreachable remote: never update"      "unknown"    "$(_autoupdate_decide "" "$A" "")"
check "nothing deployed: not ours to start"   "undeployed" "$(_autoupdate_decide "$B" "" "")"
check "deployed recorded as unknown"          "undeployed" "$(_autoupdate_decide "$B" "unknown" "")"

# A commit that failed, or was rolled back from, must not be retried every
# cycle...
check "held commit is not redeployed"         "held"       "$(_autoupdate_decide "$B" "$A" "$B")"
# ...but a newer one is a new update.
check "a newer commit than the held one"      "update"     "$(_autoupdate_decide "$C" "$A" "$B")"
# Being current wins over a stale hold.
check "current despite a hold"                "current"    "$(_autoupdate_decide "$A" "$A" "$A")"

# --- Units -------------------------------------------------------------------
SO_BIN_LINK="/usr/local/bin/sentinel-ops"
AUTO_UPDATE_CALENDAR="hourly"
service_text="$(_autoupdate_unit_text service)"
check "service runs the check through the PATH link" "1" \
    "$(grep -Fc "ExecStart=${SO_BIN_LINK} --dir ${INSTALL_DIR} --yes auto-update run-cycle" <<<"$service_text")"
check "service is a oneshot" "1" "$(grep -c '^Type=oneshot$' <<<"$service_text")"
check "service waits for the network" "1" "$(grep -c '^Wants=network-online.target$' <<<"$service_text")"

timer_text="$(_autoupdate_unit_text timer)"
check "timer uses the configured calendar" "1" "$(grep -c '^OnCalendar=hourly$' <<<"$timer_text")"
check "timer is persistent" "1" "$(grep -c '^Persistent=true$' <<<"$timer_text")"

AUTO_UPDATE_CALENDAR="*:0/15"
check "timer calendar reflects a custom expression" "1" \
    "$(grep -Fc 'OnCalendar=*:0/15' <<<"$(_autoupdate_unit_text timer)")"

# --- Update lock -------------------------------------------------------------
if have_cmd flock; then
    # Another process (the auto-update timer, say) holds it.
    mkdir -p "$STATE_DIR"
    exec 9>"${STATE_DIR}/update.lock"
    flock -n 9
    check "busy lock is refused, not waited on" "1" \
        "$( (SO_UPDATE_LOCK_FD=""; update_lock_acquire; echo $?) )"
    exec 9>&-
    check "free lock is taken" "0" "$( (SO_UPDATE_LOCK_FD=""; update_lock_acquire; echo $?) )"

    # `update all` takes it, then calls `update app`, which takes it again.
    SO_UPDATE_LOCK_FD=""
    update_lock_acquire
    check "lock is re-entrant within a process" "0" "$(update_lock_acquire; echo $?)"
    check "held lock blocks another process" "1" \
        "$(bash -c 'exec 9>"$1"; flock -n 9; echo $?' _ "${STATE_DIR}/update.lock")"

    # The menu outlives the update it ran; the timer must not starve meanwhile.
    update_lock_release
    check "released lock is free for another process" "0" \
        "$(bash -c 'exec 9>"$1"; flock -n 9; echo $?' _ "${STATE_DIR}/update.lock")"
else
    printf 'skip  update lock (flock not installed)\n'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
rm -rf "$T"
[[ $fail -eq 0 ]]
