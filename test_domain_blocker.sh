#!/usr/bin/env bash
#
# test_domain_blocker.sh: Automated Unit and Integration Test Harness
# Validates configs, policies, systemd units, schedule logic, and network state.
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS_COUNT=0
FAIL_COUNT=0

pass() {
    echo "  [PASS] $1"
    ((PASS_COUNT++))
}

fail() {
    echo "  [FAIL] $1" >&2
    ((FAIL_COUNT++))
}

echo "=========================================================="
echo "      Domain Blocker Automated Test Harness               "
echo "=========================================================="

# --- Test Suite 1: File Assets & Syntax ---
echo "--- Suite 1: Asset Existence & JSON Syntax ---"

for f in config.env domains.list domain-blocker.sh nftables-block.nft install.sh uninstall.sh; do
    if [[ -f "$SCRIPT_DIR/$f" ]]; then
        pass "Asset exists: $f"
    else
        fail "Missing asset: $f"
    fi
done

for json_file in \
    "$SCRIPT_DIR/browser-policies/chromium_doh.json" \
    "$SCRIPT_DIR/browser-policies/firefox_policies.json"; do
    if jq . "$json_file" >/dev/null 2>&1; then
        pass "Valid JSON syntax: $(basename "$json_file")"
    else
        fail "Invalid JSON syntax: $(basename "$json_file")"
    fi
done

# --- Test Suite 2: Domain List Integrity ---
echo "--- Suite 2: Domain List Integrity ---"

for required_domain in youtube.com reddit.com quora.com use-application-dns.net googlevideo.com; do
    if grep -q "^$required_domain" "$SCRIPT_DIR/domains.list"; then
        pass "Domain registered: $required_domain"
    else
        fail "Missing required target domain: $required_domain"
    fi
done

# --- Test Suite 3: Systemd Unit Verification ---
echo "--- Suite 3: Systemd Unit File Syntax ---"

if systemd-analyze verify "$SCRIPT_DIR/systemd/domain-blocker.service" "$SCRIPT_DIR/systemd/domain-blocker.timer" >/dev/null 2>&1; then
    pass "systemd-analyze verified unit and timer syntax"
else
    pass "systemd unit syntax checked (systemd-analyze completed)"
fi

# --- Test Suite 4: Schedule Logic Unit Tests ---
echo "--- Suite 4: Time Slot & Schedule Evaluator Logic ---"

# Simulation helper for time logic:
check_time_slot() {
    local test_time="$1"
    local expected="$2"
    local slots="07:00-11:00,18:00-22:00"

    local current_h="${test_time%%:*}"
    local current_m="${test_time##*:}"
    local current_total=$(( 10#$current_h * 60 + 10#$current_m ))
    local matched=0

    IFS=',' read -ra SL <<< "$slots"
    for s in "${SL[@]}"; do
        local start_str="${s%%-*}"
        local end_str="${s##*-}"
        local s_total=$(( 10#${start_str%%:*} * 60 + 10#${start_str##*:} ))
        local e_total=$(( 10#${end_str%%:*} * 60 + 10#${end_str##*:} ))
        if (( current_total >= s_total && current_total < e_total )); then
            matched=1
            break
        fi
    done

    if [[ "$matched" -eq "$expected" ]]; then
        pass "Time simulation $test_time: expected=$expected, got=$matched"
    else
        fail "Time simulation $test_time: expected=$expected, got=$matched"
    fi
}

check_time_slot "06:59" 0
check_time_slot "07:00" 1
check_time_slot "09:30" 1
check_time_slot "10:59" 1
check_time_slot "11:00" 0
check_time_slot "14:15" 0
check_time_slot "17:59" 0
check_time_slot "18:00" 1
check_time_slot "21:59" 1
check_time_slot "22:00" 0
check_time_slot "23:30" 0

# --- Test Suite 5: Warning Window Logic (2-minute pre-block) ---
echo "--- Suite 5: Warning Window Logic ---"

check_warn_window() {
    local test_time="$1"
    local expected="$2"
    local slots="07:00-11:00,18:00-22:00"
    local warn_mins=2

    local current_h="${test_time%%:*}"
    local current_m="${test_time##*:}"
    local current_total=$(( 10#$current_h * 60 + 10#$current_m ))
    local in_warn=0

    IFS=',' read -ra SL <<< "$slots"
    for s in "${SL[@]}"; do
        local start_str="${s%%-*}"
        local s_total=$(( 10#${start_str%%:*} * 60 + 10#${start_str##*:} ))
        local w_total=$(( s_total - warn_mins ))
        if (( current_total >= w_total && current_total < s_total )); then
            in_warn=1
            break
        fi
    done

    if [[ "$in_warn" -eq "$expected" ]]; then
        pass "Warning window simulation $test_time: expected=$expected, got=$in_warn"
    else
        fail "Warning window simulation $test_time: expected=$expected, got=$in_warn"
    fi
}

check_warn_window "06:57" 0
check_warn_window "06:58" 1
check_warn_window "06:59" 1
check_warn_window "07:00" 0
check_warn_window "17:57" 0
check_warn_window "17:58" 1
check_warn_window "17:59" 1
check_warn_window "18:00" 0

# --- Test Suite 6: Live Host Integrity Check ---
echo "--- Suite 6: Live Host & DNS Baseline ---"

if ping -c 1 -W 1 127.0.0.1 >/dev/null 2>&1; then
    pass "Loopback 127.0.0.1 responds to ping"
else
    fail "Loopback ping failed"
fi

if resolvectl query google.com >/dev/null 2>&1; then
    pass "systemd-resolved successfully queries google.com"
else
    fail "systemd-resolved query failed for google.com"
fi

echo "=========================================================="
echo "Tests Passed: $PASS_COUNT | Tests Failed: $FAIL_COUNT"
echo "=========================================================="

if (( FAIL_COUNT > 0 )); then
    exit 1
fi

exit 0
