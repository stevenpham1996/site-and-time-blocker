#!/usr/bin/env bash
#
# uninstall.sh: Complete clean uninstallation and rollback for Domain Blocker
# Restores original network state, /etc/hosts, browser settings, and removes services.
#

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Error: uninstall.sh must be run as root (e.g., sudo ./uninstall.sh)." >&2
    exit 1
fi

echo "=========================================================="
echo "          Uninstalling Domain Blocker                     "
echo "=========================================================="

# 1. Stop and disable systemd timers and services
echo "Stopping and disabling systemd timer..."
systemctl stop domain-blocker.timer domain-blocker.service 2>/dev/null || true
systemctl disable domain-blocker.timer domain-blocker.service 2>/dev/null || true
rm -f /etc/systemd/system/domain-blocker.service /etc/systemd/system/domain-blocker.timer
systemctl daemon-reload

# 2. Remove hooks
echo "Removing system hooks..."
rm -f /lib/systemd/system-sleep/domain-blocker-sync
rm -f /etc/NetworkManager/dispatcher.d/99-domain-blocker

# 3. Disable blocking and restore pristine /etc/hosts
echo "Restoring network and DNS state..."
if [[ -x /usr/local/bin/domain-blocker ]]; then
    /usr/local/bin/domain-blocker disable 2>/dev/null || true
fi

if [[ -f /etc/domain-blocker/hosts.original ]]; then
    echo "Restoring /etc/hosts from pristine backup..."
    cp -p /etc/domain-blocker/hosts.original /etc/hosts
    chmod 644 /etc/hosts
fi

# 4. Remove nftables table if lingering
if command -v nft >/dev/null 2>&1; then
    nft delete table inet domain_blocker 2>/dev/null || true
fi

# 5. Clear wildcard routing domains on lo
if command -v resolvectl >/dev/null 2>&1; then
    resolvectl domain lo "" >/dev/null 2>&1 || true
    resolvectl dns lo "" >/dev/null 2>&1 || true
    resolvectl flush-caches >/dev/null 2>&1 || true
fi

# 6. Remove browser policies
echo "Removing browser policies..."
rm -f /etc/opt/chrome/policies/managed/domain_blocker.json
rm -f /etc/brave/policies/managed/domain_blocker.json
rm -f /etc/chromium/policies/managed/domain_blocker.json
rm -f /etc/firefox/policies/policies.json
rm -f /var/snap/firefox/common/policies/policies.json

# 7. Remove binary and configuration directories
echo "Removing binary and configuration directory..."
rm -f /usr/local/bin/domain-blocker
rm -rf /run/domain-blocker
rm -rf /etc/domain-blocker

echo "=========================================================="
echo "      Domain Blocker Successfully Uninstalled!            "
echo "      All network settings and files have been restored.  "
echo "=========================================================="
