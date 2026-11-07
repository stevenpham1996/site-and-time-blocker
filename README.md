# Domain Blocker: System-Wide Time-Based Domain Blocking for Linux

A robust, enterprise-grade, OS-layer domain blocker targeting **YouTube**, **Reddit**, and **Quora** on Linux (Ubuntu 26.04).

## Architecture Highlights
- **Multi-Layer Enforcement:**
  - **DNS Sinkholing:** Exact domain sinkhole via atomic `/etc/hosts` synchronization and cache invalidation.
  - **Wildcard Subdomain Routing:** Dynamic video streaming servers (such as `*.googlevideo.com`) sinkholed via `systemd-resolved` loopback routing domains.
  - **Firewall Shield (nftables):** Isolated `inet domain_blocker` table blocking DNS-over-TLS (port 853) and public DNS-over-HTTPS (DoH) resolver IPs (1.1.1.1, 8.8.8.8, 9.9.9.9) on port 443 during block windows.
  - **Browser Policy Lockdown:** Enterprise policies deployed for Google Chrome, Brave, Chromium, and Mozilla Firefox (both native package and Ubuntu Snap) enforcing `DnsOverHttpsMode: "off"`.
  - **Active Session Severance:** 2-minute pre-block warning desktop notification followed by socket termination (`ss -K`) and firewall TCP resets at slot start.
  - **Network & Sleep Resilience:** Synchronizes automatically every 2 minutes via systemd timer, on resume from sleep/suspend, and on network/VPN interface state transitions via NetworkManager dispatcher.

---

## Default Schedule
- **Slot 1:** `07:00` to `11:00` (Pre-block warning at `06:58`)
- **Slot 2:** `18:00` to `22:00` (Pre-block warning at `17:58`)
- **Days:** Daily (Mon, Tue, Wed, Thu, Fri, Sat, Sun)

Configurable anytime in `/etc/domain-blocker/config.env`.

---

## Installation
Run the self-contained installer with sudo:
```bash
cd /home/pham/domain-blocker
sudo ./install.sh
```

## Management Commands
- Check current status and layers:
  ```bash
  domain-blocker status
  ```
- Run automated live connectivity & blocking verification:
  ```bash
  domain-blocker test
  ```
- Trigger schedule synchronization manually:
  ```bash
  sudo domain-blocker sync
  ```
- Test desktop notification:
  ```bash
  domain-blocker notify
  ```
- Manual administrative override (force enable/disable):
  ```bash
  sudo domain-blocker enable
  sudo domain-blocker disable
  ```

## Automated Verification Suite
Run unit and integration tests:
```bash
./test_domain_blocker.sh
```

## Uninstallation / Complete Rollback
To restore original system settings, remove firewall tables, and delete services:
```bash
sudo /home/pham/domain-blocker/uninstall.sh
```
