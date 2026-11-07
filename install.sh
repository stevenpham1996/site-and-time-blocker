#!/usr/bin/env bash
#
# install.sh: Idempotent installer for Domain Blocker
# Installs config, binary, browser policies, firewall rules, and systemd timers.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -ne 0 ]]; then
    echo "Error: install.sh must be run as root (e.g., sudo ./install.sh)." >&2
    exit 1
fi

echo "=========================================================="
echo "          Installing Domain Blocker Engine                "
echo "=========================================================="

# 1. Check prerequisites
echo -n "Checking prerequisites... "
for cmd in nft systemctl resolvectl ss awk sed; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Missing required dependency: $cmd" >&2
        exit 1
    fi
done
echo "OK"

# 2. Create configuration and state directories
echo -n "Creating system directories... "
mkdir -p /etc/domain-blocker
mkdir -p /run/domain-blocker
mkdir -p /lib/systemd/system-sleep
mkdir -p /etc/systemd/system
if [[ -d /etc/NetworkManager ]]; then
    mkdir -p /etc/NetworkManager/dispatcher.d
fi
echo "OK"

# 3. Preserve pristine /etc/hosts backup
if [[ ! -f /etc/domain-blocker/hosts.original ]]; then
    echo "Backing up pristine /etc/hosts to /etc/domain-blocker/hosts.original"
    cp -p /etc/hosts /etc/domain-blocker/hosts.original
fi

# 4. Copy configuration and data files
echo "Installing configuration assets..."
if [[ ! -f /etc/domain-blocker/config.env ]]; then
    cp "$SCRIPT_DIR/config.env" /etc/domain-blocker/config.env
    chmod 644 /etc/domain-blocker/config.env
    echo "  Installed /etc/domain-blocker/config.env"
else
    echo "  Preserved existing /etc/domain-blocker/config.env"
fi

cp "$SCRIPT_DIR/domains.list" /etc/domain-blocker/domains.list
chmod 644 /etc/domain-blocker/domains.list
echo "  Installed /etc/domain-blocker/domains.list"

cp "$SCRIPT_DIR/nftables-block.nft" /etc/domain-blocker/nftables-block.nft
chmod 644 /etc/domain-blocker/nftables-block.nft
echo "  Installed /etc/domain-blocker/nftables-block.nft"

# 5. Install CLI control engine
cp "$SCRIPT_DIR/domain-blocker.sh" /usr/local/bin/domain-blocker
chmod 755 /usr/local/bin/domain-blocker
echo "  Installed /usr/local/bin/domain-blocker (chmod 755)"

# 6. Install browser enterprise policies
echo "Installing browser enterprise policies (anti-DoH)..."
# Chrome
mkdir -p /etc/opt/chrome/policies/managed
cp "$SCRIPT_DIR/browser-policies/chromium_doh.json" /etc/opt/chrome/policies/managed/domain_blocker.json
chmod 644 /etc/opt/chrome/policies/managed/domain_blocker.json

# Brave
mkdir -p /etc/brave/policies/managed
cp "$SCRIPT_DIR/browser-policies/chromium_doh.json" /etc/brave/policies/managed/domain_blocker.json
chmod 644 /etc/brave/policies/managed/domain_blocker.json

# Chromium
mkdir -p /etc/chromium/policies/managed
cp "$SCRIPT_DIR/browser-policies/chromium_doh.json" /etc/chromium/policies/managed/domain_blocker.json
chmod 644 /etc/chromium/policies/managed/domain_blocker.json

# Firefox Native
mkdir -p /etc/firefox/policies
cp "$SCRIPT_DIR/browser-policies/firefox_policies.json" /etc/firefox/policies/policies.json
chmod 644 /etc/firefox/policies/policies.json

# Firefox Snap (Ubuntu default)
if [[ -d /var/snap/firefox ]]; then
    mkdir -p /var/snap/firefox/common/policies
    cp "$SCRIPT_DIR/browser-policies/firefox_policies.json" /var/snap/firefox/common/policies/policies.json
    chmod 644 /var/snap/firefox/common/policies/policies.json
    echo "  Applied policy to Snap Firefox (/var/snap/firefox/common/policies/policies.json)"
fi

# 7. Install systemd timer and service
echo "Installing systemd services and timers..."
cp "$SCRIPT_DIR/systemd/domain-blocker.service" /etc/systemd/system/domain-blocker.service
chmod 644 /etc/systemd/system/domain-blocker.service

cp "$SCRIPT_DIR/systemd/domain-blocker.timer" /etc/systemd/system/domain-blocker.timer
chmod 644 /etc/systemd/system/domain-blocker.timer

# 8. Install sleep/resume and NetworkManager dispatcher hooks
cp "$SCRIPT_DIR/hooks/domain-blocker-sync" /lib/systemd/system-sleep/domain-blocker-sync
chmod 755 /lib/systemd/system-sleep/domain-blocker-sync

if [[ -d /etc/NetworkManager/dispatcher.d ]]; then
    cp "$SCRIPT_DIR/hooks/99-domain-blocker" /etc/NetworkManager/dispatcher.d/99-domain-blocker
    chmod 755 /etc/NetworkManager/dispatcher.d/99-domain-blocker
fi

# 9. Enable and start systemd timer
systemctl daemon-reload
systemctl enable --now domain-blocker.timer
echo "  Enabled and started domain-blocker.timer"

# 10. Initial state sync
echo "Executing initial state synchronization..."
/usr/local/bin/domain-blocker sync

echo "=========================================================="
echo "      Domain Blocker Installation Complete!              "
echo "=========================================================="
echo "Status check    : domain-blocker status"
echo "Verification    : domain-blocker test"
echo "Manual control  : sudo domain-blocker {enable|disable|sync}"
echo "Configuration   : /etc/domain-blocker/config.env"
echo "Uninstall       : sudo $SCRIPT_DIR/uninstall.sh"
echo "=========================================================="
