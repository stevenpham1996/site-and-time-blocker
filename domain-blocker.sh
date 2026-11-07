#!/usr/bin/env bash
#
# domain-blocker: System-Wide Time-Based Domain Blocking Engine on Linux
# Targets: YouTube, Reddit, Quora, and associated dynamic CDNs
# Features: /etc/hosts sinkhole, systemd-resolved wildcard routing, nftables DoH/DoT drop,
#           browser enterprise policies, pre-block warning, and active socket kill.
#

set -o pipefail

# --- Path Configurations ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-/etc/domain-blocker/config.env}"

# Fall back to script local directory if /etc/domain-blocker is not yet installed
if [[ ! -f "$CONFIG_FILE" && -f "$SCRIPT_DIR/config.env" ]]; then
    CONFIG_FILE="$SCRIPT_DIR/config.env"
fi

if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# Default fallback settings
SCHEDULE_SLOTS="${SCHEDULE_SLOTS:-07:00-11:00,18:00-22:00}"
SCHEDULE_DAYS="${SCHEDULE_DAYS:-all}"
PRE_BLOCK_WARN_MINUTES="${PRE_BLOCK_WARN_MINUTES:-2}"
ENFORCE_FIREWALL="${ENFORCE_FIREWALL:-1}"
ENFORCE_BROWSER_POLICIES="${ENFORCE_BROWSER_POLICIES:-1}"
KILL_ACTIVE_SOCKETS="${KILL_ACTIVE_SOCKETS:-1}"
WILDCARD_ROUTING="${WILDCARD_ROUTING:-1}"

DOMAINS_FILE="${DOMAINS_FILE:-/etc/domain-blocker/domains.list}"
if [[ ! -f "$DOMAINS_FILE" && -f "$SCRIPT_DIR/domains.list" ]]; then
    DOMAINS_FILE="$SCRIPT_DIR/domains.list"
fi

NFT_RULES="${NFT_RULES:-/etc/domain-blocker/nftables-block.nft}"
if [[ ! -f "$NFT_RULES" && -f "$SCRIPT_DIR/nftables-block.nft" ]]; then
    NFT_RULES="$SCRIPT_DIR/nftables-block.nft"
fi

HOSTS_FILE="${HOSTS_FILE:-/etc/hosts}"
HOSTS_BACKUP="${HOSTS_BACKUP:-/etc/domain-blocker/hosts.original}"
STATE_DIR="${STATE_DIR:-/run/domain-blocker}"
STATUS_FILE="$STATE_DIR/status"
WARN_SENT_FILE="$STATE_DIR/warn_sent"
LOG_TAG="domain-blocker"

MARKER_BEGIN="# BEGIN DOMAIN-BLOCKER MANAGED REGION"
MARKER_END="# END DOMAIN-BLOCKER MANAGED REGION"

# --- Helper Utilities ---

log() {
    local msg="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg"
    logger -t "$LOG_TAG" "$msg" 2>/dev/null || true
}

warn() {
    local msg="$1"
    echo "[WARNING] $msg" >&2
    logger -t "$LOG_TAG" "[WARNING] $msg" 2>/dev/null || true
}

error() {
    local msg="$1"
    echo "[ERROR] $msg" >&2
    logger -t "$LOG_TAG" "[ERROR] $msg" 2>/dev/null || true
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Error: This operation requires root privileges. Please run with sudo." >&2
        exit 1
    fi
}

init_state_dir() {
    if [[ ! -d "$STATE_DIR" ]]; then
        mkdir -p "$STATE_DIR"
        chmod 755 "$STATE_DIR"
    fi
}

# --- Schedule Calculation ---

# Returns 0 if current time falls into any configured slot, 1 otherwise
is_in_schedule() {
    local current_day current_hour current_min current_total
    current_day=$(date +%a)
    current_hour=$(date +%-H)
    current_min=$(date +%-M)
    current_total=$(( current_hour * 60 + current_min ))

    # Check day of week
    if [[ "$SCHEDULE_DAYS" != "all" && "$SCHEDULE_DAYS" != "All" ]]; then
        if ! echo ",$SCHEDULE_DAYS," | grep -qi ",$current_day,"; then
            return 1
        fi
    fi

    # Parse comma-separated slots
    IFS=',' read -ra SLOTS <<< "$SCHEDULE_SLOTS"
    for slot in "${SLOTS[@]}"; do
        slot=$(echo "$slot" | tr -d '[:space:]')
        if [[ -z "$slot" ]]; then continue; fi
        
        local start_str end_str
        start_str="${slot%%-*}"
        end_str="${slot##*-}"

        local start_h start_m start_total
        start_h=${start_str%%:*}
        start_m=${start_str##*:}
        start_total=$(( 10#$start_h * 60 + 10#$start_m ))

        local end_h end_m end_total
        end_h=${end_str%%:*}
        end_m=${end_str##*:}
        end_total=$(( 10#$end_h * 60 + 10#$end_m ))

        if (( current_total >= start_total && current_total < end_total )); then
            return 0
        fi
    done

    return 1
}

# Returns 0 if current time is within PRE_BLOCK_WARN_MINUTES before any slot start
is_in_warning_window() {
    if (( PRE_BLOCK_WARN_MINUTES <= 0 )); then
        return 1
    fi

    local current_day current_hour current_min current_total
    current_day=$(date +%a)
    current_hour=$(date +%-H)
    current_min=$(date +%-M)
    current_total=$(( current_hour * 60 + current_min ))

    if [[ "$SCHEDULE_DAYS" != "all" && "$SCHEDULE_DAYS" != "All" ]]; then
        if ! echo ",$SCHEDULE_DAYS," | grep -qi ",$current_day,"; then
            return 1
        fi
    fi

    IFS=',' read -ra SLOTS <<< "$SCHEDULE_SLOTS"
    for slot in "${SLOTS[@]}"; do
        slot=$(echo "$slot" | tr -d '[:space:]')
        if [[ -z "$slot" ]]; then continue; fi

        local start_str start_h start_m start_total warn_total
        start_str="${slot%%-*}"
        start_h=${start_str%%:*}
        start_m=${start_str##*:}
        start_total=$(( 10#$start_h * 60 + 10#$start_m ))
        warn_total=$(( start_total - PRE_BLOCK_WARN_MINUTES ))

        if (( current_total >= warn_total && current_total < start_total )); then
            return 0
        fi
    done

    return 1
}

# --- Notification Dispatcher ---

send_notification() {
    local title="${1:-Domain Blocker Warning}"
    local body="${2:-Scheduled domain block begins in 2 minutes for YouTube, Reddit, and Quora.}"

    log "Broadcasting desktop notification: $title - $body"

    # Find active graphical user login sessions
    for user_bus in /run/user/[0-9]*/bus; do
        if [[ -S "$user_bus" ]]; then
            local uid
            uid=$(basename "$(dirname "$user_bus")")
            local uname
            uname=$(id -nu "$uid" 2>/dev/null || true)
            if [[ -n "$uname" ]]; then
                sudo -u "$uname" \
                    DBUS_SESSION_BUS_ADDRESS="unix:path=$user_bus" \
                    notify-send -u critical -i network-error "$title" "$body" 2>/dev/null || true
            fi
        fi
    done
}

# --- DNS Sinkholing (/etc/hosts) ---

apply_hosts_block() {
    if [[ ! -f "$DOMAINS_FILE" ]]; then
        error "Domains file not found: $DOMAINS_FILE"
        return 1
    fi

    # Ensure a pristine original backup exists
    if [[ ! -f "$HOSTS_BACKUP" ]]; then
        cp -p "$HOSTS_FILE" "$HOSTS_BACKUP"
    fi

    local tmp_hosts
    tmp_hosts=$(mktemp /tmp/hosts.block.XXXXXX)

    # Strip existing managed region if present
    awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" '
        $0 == b { skip=1; next }
        $0 == e { skip=0; next }
        !skip { print }
    ' "$HOSTS_FILE" > "$tmp_hosts"

    # Append fresh managed entries
    {
        echo "$MARKER_BEGIN"
        echo "# Generated by Domain Blocker on $(date)"
        while IFS= read -r line || [[ -n "$line" ]]; do
            # Trim whitespace and comments
            line=$(echo "$line" | sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//')
            if [[ -n "$line" ]]; then
                echo "0.0.0.0 $line"
                echo "::1 $line"
            fi
        done < "$DOMAINS_FILE"
        echo "$MARKER_END"
    } >> "$tmp_hosts"

    # Safety check: Verify localhost and 127.0.0.1 remain intact
    if ! grep -q "127.0.0.1" "$tmp_hosts" || ! grep -q "localhost" "$tmp_hosts"; then
        error "Integrity check failed: hosts file candidate lacks 127.0.0.1 or localhost! Aborting."
        rm -f "$tmp_hosts"
        return 1
    fi

    cp -p "$HOSTS_FILE" "${HOSTS_FILE}.bak"
    mv "$tmp_hosts" "$HOSTS_FILE"
    chmod 644 "$HOSTS_FILE"
    log "Applied domain sinkhole block to $HOSTS_FILE"
    return 0
}

remove_hosts_block() {
    if ! grep -q "$MARKER_BEGIN" "$HOSTS_FILE"; then
        return 0
    fi

    local tmp_hosts
    tmp_hosts=$(mktemp /tmp/hosts.unblock.XXXXXX)

    awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" '
        $0 == b { skip=1; next }
        $0 == e { skip=0; next }
        !skip { print }
    ' "$HOSTS_FILE" > "$tmp_hosts"

    if ! grep -q "127.0.0.1" "$tmp_hosts" || ! grep -q "localhost" "$tmp_hosts"; then
        error "Integrity check failed when unblocking hosts. Restoring from $HOSTS_BACKUP."
        if [[ -f "$HOSTS_BACKUP" ]]; then
            cp -p "$HOSTS_BACKUP" "$HOSTS_FILE"
        fi
        rm -f "$tmp_hosts"
        return 1
    fi

    mv "$tmp_hosts" "$HOSTS_FILE"
    chmod 644 "$HOSTS_FILE"
    log "Removed domain sinkhole block from $HOSTS_FILE"
    return 0
}

# --- Systemd-resolved Wildcard Routing ---

apply_wildcard_routing() {
    if (( WILDCARD_ROUTING != 1 )); then
        return 0
    fi

    if command -v resolvectl >/dev/null 2>&1; then
        # Attach routing domains to loopback (lo) pointing to sinkhole 127.0.0.2
        resolvectl domain lo ~youtube.com ~googlevideo.com ~ytimg.com ~reddit.com ~redd.it ~redditmedia.com ~redditstatic.com ~quora.com ~quoracdn.net >/dev/null 2>&1 || true
        resolvectl dns lo 127.0.0.2 >/dev/null 2>&1 || true
        resolvectl flush-caches >/dev/null 2>&1 || true
        log "Applied wildcard routing domains on lo via resolvectl"
    fi
}

remove_wildcard_routing() {
    if command -v resolvectl >/dev/null 2>&1; then
        resolvectl domain lo "" >/dev/null 2>&1 || true
        resolvectl dns lo "" >/dev/null 2>&1 || true
        resolvectl flush-caches >/dev/null 2>&1 || true
        log "Cleared wildcard routing domains on lo via resolvectl"
    fi
}

# --- Firewall Layer (nftables) ---

apply_nftables() {
    if (( ENFORCE_FIREWALL != 1 )); then
        return 0
    fi

    if [[ ! -f "$NFT_RULES" ]]; then
        warn "nftables ruleset file not found: $NFT_RULES. Skipping firewall rule application."
        return 0
    fi

    if command -v nft >/dev/null 2>&1; then
        nft -f "$NFT_RULES" 2>&1 | logger -t "$LOG_TAG" || true
        log "Applied nftables domain_blocker ruleset"
    fi
}

remove_nftables() {
    if command -v nft >/dev/null 2>&1; then
        nft delete table inet domain_blocker 2>/dev/null || true
        log "Removed nftables table inet domain_blocker"
    fi
}

# --- Active Socket Severance ---

sever_active_sockets() {
    if (( KILL_ACTIVE_SOCKETS != 1 )); then
        return 0
    fi

    if command -v ss >/dev/null 2>&1; then
        # Kill open sockets to public DoH resolvers
        for doh_ip in 1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 9.9.9.9 149.112.112.112; do
            ss -K dst "$doh_ip" >/dev/null 2>&1 || true
        done

        # Query and kill active sockets to target domains
        if [[ -f "$DOMAINS_FILE" ]]; then
            while IFS= read -r domain || [[ -n "$domain" ]]; do
                domain=$(echo "$domain" | sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//')
                if [[ -n "$domain" && "$domain" != "use-application-dns.net" ]]; then
                    # Get previously cached IPs if any
                    local ips
                    ips=$(getent ahosts "$domain" 2>/dev/null | awk '{print $1}' | grep -v -E "^(0\.0\.0\.0|127\.|::1)" | sort -u || true)
                    for ip in $ips; do
                        ss -K dst "$ip" >/dev/null 2>&1 || true
                    done
                fi
            done < "$DOMAINS_FILE"
        fi
        log "Severed existing active sockets to target endpoints"
    fi
}

# --- Core Lifecycle Transitions ---

do_enable() {
    check_root
    init_state_dir
    log "Initiating ENABLE transition..."

    local failed=0
    apply_hosts_block || failed=1
    apply_wildcard_routing || failed=1
    apply_nftables || failed=1
    sever_active_sockets || true

    if (( failed == 1 )); then
        error "Enable transition failed! Performing emergency auto-recovery rollback."
        do_disable
        echo "ERROR" > "$STATUS_FILE"
        return 1
    fi

    echo "BLOCKED" > "$STATUS_FILE"
    rm -f "$WARN_SENT_FILE"
    log "Domain blocker is now ACTIVE (BLOCKED)"
    return 0
}

do_disable() {
    check_root
    init_state_dir
    log "Initiating DISABLE transition..."

    remove_hosts_block || true
    remove_wildcard_routing || true
    remove_nftables || true

    echo "UNBLOCKED" > "$STATUS_FILE"
    rm -f "$WARN_SENT_FILE"
    log "Domain blocker is now INACTIVE (UNBLOCKED)"
    return 0
}

# --- State Sync (Called by Timer & Dispatchers) ---

do_sync() {
    check_root
    init_state_dir

    local current_status="UNKNOWN"
    if [[ -f "$STATUS_FILE" ]]; then
        current_status=$(cat "$STATUS_FILE")
    fi

    # 1. Check Pre-Block Warning
    if is_in_warning_window; then
        if [[ ! -f "$WARN_SENT_FILE" ]]; then
            send_notification "Domain Blocker Warning" "Focus block for YouTube, Reddit, and Quora starts in $PRE_BLOCK_WARN_MINUTES minutes."
            touch "$WARN_SENT_FILE"
        fi
    fi

    # 2. Check Active Schedule
    if is_in_schedule; then
        if [[ "$current_status" != "BLOCKED" ]]; then
            log "Schedule match detected: transitioning to BLOCKED"
            do_enable
        else
            # Self-healing: verify rules are still present
            if ! grep -q "$MARKER_BEGIN" "$HOSTS_FILE"; then
                log "Self-healing: hosts file tampering detected, re-applying block"
                apply_hosts_block
            fi
        fi
    else
        if [[ "$current_status" == "BLOCKED" ]]; then
            log "Schedule ended: transitioning to UNBLOCKED"
            do_disable
        fi
    fi
}

# --- Status & Diagnostic Report ---

do_status() {
    local current_time current_day
    current_time=$(date '+%Y-%m-%d %H:%M:%S %Z')
    current_day=$(date +%a)

    echo "=========================================================="
    echo "            Domain Blocker System Status                  "
    echo "=========================================================="
    echo "Current System Time : $current_time ($current_day)"
    echo "Configured Slots    : $SCHEDULE_SLOTS"
    echo "Configured Days     : $SCHEDULE_DAYS"

    if is_in_schedule; then
        echo "Schedule State      : INSIDE SCHEDULED BLOCK WINDOW"
    elif is_in_warning_window; then
        echo "Schedule State      : INSIDE PRE-BLOCK WARNING WINDOW (T-$PRE_BLOCK_WARN_MINUTES min)"
    else
        echo "Schedule State      : OUTSIDE SCHEDULED WINDOW (ALLOWED)"
    fi

    local current_state="UNBLOCKED"
    if [[ -f "$STATUS_FILE" ]]; then
        current_state=$(cat "$STATUS_FILE")
    fi
    echo "Recorded State      : $current_state"

    echo "----------------------------------------------------------"
    echo "Enforcement Layers:"
    
    # 1. Hosts check
    if grep -q "$MARKER_BEGIN" "$HOSTS_FILE" 2>/dev/null; then
        local count
        count=$(grep -c "0.0.0.0" "$HOSTS_FILE" 2>/dev/null || echo "0")
        echo "  [✓] /etc/hosts Sinkhole     : ACTIVE ($count entries)"
    else
        echo "  [ ] /etc/hosts Sinkhole     : INACTIVE"
    fi

    # 2. Systemd-resolved routing check
    if command -v resolvectl >/dev/null 2>&1; then
        if resolvectl domain lo 2>/dev/null | grep -q "youtube.com"; then
            echo "  [✓] Wildcard DNS Routing    : ACTIVE on lo"
        else
            echo "  [ ] Wildcard DNS Routing    : INACTIVE"
        fi
    fi

    # 3. nftables check
    if command -v nft >/dev/null 2>&1; then
        if nft list tables 2>/dev/null | grep -q "domain_blocker"; then
            echo "  [✓] nftables Firewall Table : ACTIVE (table inet domain_blocker)"
        else
            echo "  [ ] nftables Firewall Table : INACTIVE"
        fi
    fi

    # 4. Browser policies check
    echo "Browser Enterprise Policies:"
    for p in \
        "/etc/opt/chrome/policies/managed/domain_blocker.json" \
        "/etc/brave/policies/managed/domain_blocker.json" \
        "/etc/chromium/policies/managed/domain_blocker.json" \
        "/etc/firefox/policies/policies.json" \
        "/var/snap/firefox/common/policies/policies.json"; do
        if [[ -f "$p" ]]; then
            echo "  [✓] $p"
        else
            echo "  [ ] $p (not present)"
        fi
    done
    echo "=========================================================="
}

# --- Automated Test Suite ---

do_test() {
    echo "=========================================================="
    echo "            Domain Blocker Verification Test              "
    echo "=========================================================="
    
    local test_domains=(
        "youtube.com"
        "www.youtube.com"
        "reddit.com"
        "www.reddit.com"
        "quora.com"
    )

    local is_blocked=0
    if grep -q "$MARKER_BEGIN" "$HOSTS_FILE" 2>/dev/null; then
        is_blocked=1
        echo "Current Mode: BLOCKING ACTIVE (Tests should verify domains are BLOCKED)"
    else
        echo "Current Mode: BLOCKING INACTIVE (Tests should verify domains are ACCESSIBLE)"
    fi
    echo "----------------------------------------------------------"

    # Test 1: Loopback & Essential Network Sanity
    echo -n "Checking Loopback Interface (127.0.0.1)... "
    if ping -c 1 -W 1 127.0.0.1 >/dev/null 2>&1; then
        echo "[PASS]"
    else
        echo "[FAIL]"
    fi

    echo -n "Checking External Allowed Domain (google.com)... "
    local ext_ip
    ext_ip=$(getent ahosts google.com 2>/dev/null | head -n1 | awk '{print $1}')
    if [[ -n "$ext_ip" && "$ext_ip" != "0.0.0.0" ]]; then
        echo "[PASS] (Resolved to $ext_ip)"
    else
        echo "[FAIL]"
    fi

    # Test 2: Target Domains Resolution and HTTP Probe
    for d in "${test_domains[@]}"; do
        echo -n "Testing $d DNS resolution... "
        local res_ip
        res_ip=$(getent ahosts "$d" 2>/dev/null | head -n1 | awk '{print $1}')
        if [[ "$is_blocked" -eq 1 ]]; then
            if [[ "$res_ip" == "0.0.0.0" || "$res_ip" == "::1" || -z "$res_ip" ]]; then
                echo "[PASS] (Blocked: $res_ip)"
            else
                echo "[FAIL] (Leaked IP: $res_ip)"
            fi
        else
            if [[ -n "$res_ip" && "$res_ip" != "0.0.0.0" ]]; then
                echo "[PASS] (Accessible: $res_ip)"
            else
                echo "[FAIL] (Unexpectedly sinkholed: $res_ip)"
            fi
        fi

        echo -n "Testing $d HTTP/HTTPS handshake... "
        if curl -Is --connect-timeout 2 "https://$d" >/dev/null 2>&1; then
            if [[ "$is_blocked" -eq 1 ]]; then
                echo "[FAIL] (Connection succeeded unexpectedly)"
            else
                echo "[PASS] (Connection succeeded as expected)"
            fi
        else
            if [[ "$is_blocked" -eq 1 ]]; then
                echo "[PASS] (Connection rejected/dropped as expected)"
            else
                echo "[FAIL] (Connection failed unexpectedly)"
            fi
        fi
    done

    # Test 3: DoH Public Resolver Direct Probe
    echo -n "Testing Anti-DoH Firewall Guard (1.1.1.1:443)... "
    if [[ "$is_blocked" -eq 1 && "$ENFORCE_FIREWALL" -eq 1 ]]; then
        if curl -Is --connect-timeout 2 "https://1.1.1.1" >/dev/null 2>&1; then
            echo "[WARN] (Port 443 accessible on 1.1.1.1; verify nftables table)"
        else
            echo "[PASS] (Direct DoH connection dropped/rejected)"
        fi
    else
        echo "[SKIP] (Blocking not currently active)"
    fi
    echo "=========================================================="
}

# --- Main Dispatcher ---

case "$1" in
    enable)
        do_enable
        ;;
    disable)
        do_disable
        ;;
    sync)
        do_sync
        ;;
    status)
        do_status
        ;;
    test)
        do_test
        ;;
    notify)
        send_notification "Test Notification" "Domain blocker notification subsystem test."
        ;;
    *)
        echo "Usage: domain-blocker {status|sync|test|enable|disable|notify}"
        echo ""
        echo "Commands:"
        echo "  status  - Show schedule and current enforcement layers status"
        echo "  sync    - Re-evaluate schedule and synchronize state (used by systemd)"
        echo "  test    - Run diagnostic checks verifying domain blocking"
        echo "  enable  - Manually force domain blocking ON"
        echo "  disable - Manually force domain blocking OFF"
        echo "  notify  - Send a test desktop warning notification"
        exit 1
        ;;
esac
