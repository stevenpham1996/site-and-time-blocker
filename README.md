# Domain Blocker: System-Wide Time-Based Domain Blocking for Linux

A tamper-resistant, multi-layered, OS-level domain blocking engine engineered for modern Linux workstations (tested on Ubuntu 26.04 / Debian / modern Linux distributions). It restricts access to targeted distraction domains (**YouTube**, **Reddit**, and **Quora**, including dynamic video streaming CDNs) during scheduled time windows across all browsers, background daemons, and desktop applications.

---

## Table of Contents
1. [Why Traditional Solutions Fail](#why-traditional-solutions-fail)
2. [Multi-Layer Architecture Deep Dive](#multi-layer-architecture-deep-dive)
3. [Schedule & Timing Logic](#schedule--timing-logic)
4. [Project Structure & File Map](#project-structure--file-map)
5. [Prerequisites & System Compatibility](#prerequisites--system-compatibility)
6. [Installation & Deployment](#installation--deployment)
7. [Operational Manual (CLI Commands)](#operational-manual-cli-commands)
8. [Configuration Guide (`config.env`)](#configuration-guide-configenv)
9. [Managing Target Domains & Wildcards](#managing-target-domains--wildcards)
10. [Automated Verification & Diagnostics](#automated-verification--diagnostics)
11. [Uninstallation & Clean Rollback](#uninstallation--clean-rollback)
12. [Troubleshooting & Verification Checklist](#troubleshooting--verification-checklist)
13. [Migration & Portability Guide (Other Distros)](#migration--portability-guide-other-distros)

---

## Why Traditional Solutions Fail

On modern Linux desktops, basic blocking techniques easily fall apart due to multiple modern networking and browser technologies:

| Mechanism | Why It Bypasses Basic Blocks | How Domain Blocker Solves It |
| :--- | :--- | :--- |
| **DNS-over-HTTPS (DoH)** | Modern browsers (Chrome, Brave, Firefox) query remote DoH servers (e.g., Cloudflare `1.1.1.1` or Google `8.8.8.8`) over HTTPS (port 443), ignoring `/etc/hosts` and local DNS. | **Multi-tier lock:**<br>1. Enterprise policies injected for Chrome, Brave, Chromium, and Firefox (deb & Snap) locking DoH to `off`.<br>2. Canary domain `use-application-dns.net` sinkholed.<br>3. `nftables` firewall drops outbound traffic to public DoH IPs and DoT (port 853). |
| **Dynamic Video CDNs (`*.googlevideo.com`)** | YouTube serves media chunks via dynamic CDN hashes (`r*---sn-*.googlevideo.com`) that cannot be individually enumerated in static `/etc/hosts`. | Configures `systemd-resolved` loopback routing domains (`resolvectl domain lo ~googlevideo.com ...`) to sinkhole arbitrary dynamic subdomains natively. |
| **QUIC / HTTP/3 (UDP 443)** | YouTube and Google services use QUIC over UDP 443. Existing sessions can migrate and maintain video streams without triggering standard TCP resets. | Drops outbound UDP 443 to target endpoints via `nftables`, forcing immediate fallback to TCP where resets and DNS sinkholing take immediate effect. |
| **Existing Socket Keep-Alive** | Open browser tabs maintain long-lived HTTP/2 or WebSocket connections that remain functional even after DNS records are sinkholed. | Triggers kernel socket termination (`ss -K`) on transition to `BLOCKED`, severing open TCP streams and forcing browsers to reload. |
| **Sleep / Suspend Drift** | Laptops suspended before a block window wakes up midway through the window; fixed-time cron/timers fail to execute. | Dual-trigger automation: systemd timer checks every 2 minutes (`*:0/2`) with `Persistent=true`, supplemented by a system-sleep post-wake hook in `/lib/systemd/system-sleep/`. |
| **VPN & Dynamic Interfaces** | Connecting to OpenVPN, WireGuard, or Tailscale rewrites `/etc/resolv.conf` or routes traffic around local firewall rules. | `nftables` rules attach to the global `output` hook across all interfaces (`tun*`, `wg*`), and a NetworkManager dispatcher script triggers state synchronization on interface events. |

---

## Multi-Layer Architecture Deep Dive

```
                                  +---------------------------------------+
                                  |     Trigger Layer (Automated)         |
                                  |  - Systemd Timer (Every 2 minutes)    |
                                  |  - Systemd Sleep-Wake Hook (Post)     |
                                  |  - NetworkManager Dispatcher (VPN/Net)|
                                  +-------------------+-------------------+
                                                      |
                                                      v
                                  +---------------------------------------+
                                  |     /usr/local/bin/domain-blocker     |
                                  |               (CLI Engine)            |
                                  +-------------------+-------------------+
                                                      |
                         +----------------------------+----------------------------+
                         |                                                         |
        [T - 2 Minutes: Pre-Block Window]                         [T - 0 Minutes: Active Block Slot]
                         |                                                         |
                         v                                                         v
         +-------------------------------+                     +---------------------------------------+
         | DBus Desktop Notification     |                     |           Multi-Layer Lockdown        |
         | Broadcast to all GUI sessions |                     +-------------------+-------------------+
         +-------------------------------+                                         |
                                            +--------------------------------------+--------------------------------------+
                                            |                                      |                                      |
                                            v                                      v                                      v
                             +-----------------------------+        +-----------------------------+        +-----------------------------+
                             |   Layer 1: DNS Resolution   |        |   Layer 2: Network Firewall |        |   Layer 3: Browser Policies |
                             +-----------------------------+        +-----------------------------+        +-----------------------------+
                             | - /etc/hosts Managed Region |        | - Isolated nftables table   |        | - Chrome & Chromium managed |
                             | - resolvectl ~lo routing    |        |   (table inet domain_blocker|        |   policy: DnsOverHttps=off  |
                             |   wildcard domains          |        | - Block DoT (port 853)      |        | - Brave managed policy      |
                             | - Canary sinkhole:          |        | - Block DoH IPs (port 443)  |        | - Firefox native & Snap     |
                             |   use-application-dns.net   |        | - Kernel socket kill (ss -K)|        |   policy: DNSOverHTTPS=off  |
                             | - resolvectl flush-caches   |        | - Fail-safe auto rollback   |        | - Force system DNS routing  |
                             +-----------------------------+        +-----------------------------+        +-----------------------------+
```

### Detailed Layer Functions:

1. **Layer 1: Atomic DNS Sinkholing (`/etc/hosts`)**
   - The engine maintains a strictly bounded managed region between `# BEGIN DOMAIN-BLOCKER MANAGED REGION` and `# END DOMAIN-BLOCKER MANAGED REGION`.
   - Domains in `domains.list` are mapped to `0.0.0.0` (IPv4 sinkhole) and `::1` (IPv6 loopback).
   - **Integrity Guard:** Before swapping `/etc/hosts`, the engine verifies that `localhost` and `127.0.0.1` are present. If missing, it aborts immediately and restores the original backup (`/etc/domain-blocker/hosts.original`).

2. **Layer 2: Wildcard Dynamic Subdomain Routing (`systemd-resolved`)**
   - In modern Linux, `systemd-resolved` operates a local stub resolver on `127.0.0.53:53`.
   - Domain Blocker attaches routing-only search domains (`~googlevideo.com`, `~youtube.com`, `~reddit.com`, `~quora.com`) to the persistent loopback interface (`lo`) with dummy DNS `127.0.0.2`.
   - Systemd-resolved routes all subdomains of these targets to the blackhole with longest-prefix priority, preventing any upstream DNS leaks.

3. **Layer 3: Firewall Anti-Bypass Shield (`nftables`)**
   - An isolated table `table inet domain_blocker` is loaded atomically via `nft -f /etc/domain-blocker/nftables-block.nft`.
   - Loopback traffic (`oifname "lo"`) is explicitly whitelisted.
   - Outbound DNS-over-TLS (port 853) and public DoH resolvers (`1.1.1.1`, `8.8.8.8`, `9.9.9.9`, `208.67.222.222`, etc.) on port 443 are rejected with TCP resets.
   - Unblocking is clean and isolated: `nft delete table inet domain_blocker` destroys the table without touching Docker, UFW, or existing workstation firewall rules.

4. **Layer 4: Browser Enterprise Policies**
   - System policy files prevent browsers from overriding local DNS:
     - `/etc/opt/chrome/policies/managed/domain_blocker.json` (Google Chrome)
     - `/etc/brave/policies/managed/domain_blocker.json` (Brave Browser)
     - `/etc/chromium/policies/managed/domain_blocker.json` (Chromium)
     - `/etc/firefox/policies/policies.json` (Mozilla Firefox native)
     - `/var/snap/firefox/common/policies/policies.json` (Mozilla Firefox Snap)
   - These set `DnsOverHttpsMode: "off"` and lock the UI preferences.

5. **Layer 5: Pre-Block Warning & Socket Termination**
   - **Pre-Block Warning:** Exactly 2 minutes before a block slot (e.g., at `06:58` and `17:58`), the daemon inspects `/run/user/<UID>/bus` and dispatches a critical desktop notification via `notify-send` to active graphical sessions.
   - **Socket Kill:** At the start of the block slot, `ss -K dst <IP>` forcibly closes open sockets to target endpoints, immediately halting video buffers and streaming sessions.

---

## Schedule & Timing Logic

The default configuration defines two daily focus windows:
- **Morning Slot:** `07:00` to `11:00` (Pre-block alert at `06:58`)
- **Evening Slot:** `18:00` to `22:00` (Pre-block alert at `17:58`)
- **Active Days:** Every day (Mon, Tue, Wed, Thu, Fri, Sat, Sun)

### Algorithm:
1. Every 2 minutes, `domain-blocker sync` is triggered by systemd timer.
2. The script converts current time into total minutes since midnight (`hour * 60 + min`).
3. If `current_mins >= start_mins - 2 && current_mins < start_mins`:
   - Checks if a warning has already been sent for this slot (`/run/domain-blocker/warn_sent`).
   - If not, broadcasts desktop notification and touches the tracking file.
4. If `current_mins >= start_mins && current_mins < end_mins`:
   - Evaluates current recorded state. If `UNBLOCKED`, executes `do_enable`.
   - If already `BLOCKED`, executes self-healing: verifies `/etc/hosts` and `nftables` have not been altered.
5. If `current_mins < start_mins || current_mins >= end_mins`:
   - If current recorded state is `BLOCKED`, executes `do_disable` and clears warning flags.

---

## Project Structure & File Map

```
/home/pham/domain-blocker/
├── README.md                           # This comprehensive technical guide
├── config.env                          # Configuration options & schedule slots
├── domains.list                        # Target domain & CDN list
├── domain-blocker.sh                   # Core executable engine & CLI
├── nftables-block.nft                  # nftables firewall ruleset template
├── install.sh                          # Idempotent system-wide installer
├── uninstall.sh                        # Complete uninstallation & rollback script
├── test_domain_blocker.sh              # Automated test suite (35 unit/integration tests)
│
├── browser-policies/                   # Enterprise policy templates
│   ├── chromium_doh.json               # Chrome / Brave / Chromium DoH lock
│   └── firefox_policies.json           # Firefox native / Snap DoH lock
│
├── systemd/                            # Systemd service & timer templates
│   ├── domain-blocker.service          # Oneshot service executing sync
│   └── domain-blocker.timer            # Timer running every 2 minutes & on boot
│
└── hooks/                              # System event hook scripts
    ├── domain-blocker-sync             # Sleep-wake post hook (/lib/systemd/system-sleep/)
    └── 99-domain-blocker               # NetworkManager dispatcher hook
```

---

## Prerequisites & System Compatibility

The solution relies entirely on native Linux tools:
- **Operating System:** Linux with kernel 5.x or 6.x / 7.x (Ubuntu 22.04 / 24.04 / 26.04, Debian 12+, Fedora 38+, Arch Linux).
- **Core Utilities:** `nft` (nftables), `systemctl` (systemd), `resolvectl` (systemd-resolved), `ss` (iproute2), `awk`, `sed`.
- **Optional Tools:** `notify-send` (for desktop alerts), `jq` & `systemd-analyze` (for test validation).

Verify prerequisites on your system:
```bash
which nft systemctl resolvectl ss awk sed notify-send
```

---

## Installation & Deployment

To install and activate Domain Blocker on your workstation:

```bash
cd /home/pham/domain-blocker
sudo ./install.sh
```

### What `install.sh` Does:
1. Creates `/etc/domain-blocker/` and backs up `/etc/hosts` to `/etc/domain-blocker/hosts.original`.
2. Copies `config.env`, `domains.list`, and `nftables-block.nft` into `/etc/domain-blocker/`.
3. Installs `domain-blocker.sh` into `/usr/local/bin/domain-blocker` (`chmod 755`).
4. Deploys browser policies across Chrome, Brave, Chromium, and Firefox (native + Snap paths).
5. Installs `domain-blocker.service` and `domain-blocker.timer` into `/etc/systemd/system/`.
6. Installs post-wake hook in `/lib/systemd/system-sleep/` and NetworkManager dispatcher in `/etc/NetworkManager/dispatcher.d/`.
7. Reloads systemd (`systemctl daemon-reload`), enables the timer (`systemctl enable --now domain-blocker.timer`), and triggers an initial `sync`.

---

## Operational Manual (CLI Commands)

The CLI tool `/usr/local/bin/domain-blocker` is accessible system-wide.

### 1. View System Status & Active Layers
```bash
domain-blocker status
```
*Sample Output:*
```
==========================================================
            Domain Blocker System Status                  
==========================================================
Current System Time : 2026-11-07 22:58:10 +07 (Sat)
Configured Slots    : 07:00-11:00,18:00-22:00
Configured Days     : all
Schedule State      : OUTSIDE SCHEDULED WINDOW (ALLOWED)
Recorded State      : UNBLOCKED
----------------------------------------------------------
Enforcement Layers:
  [ ] /etc/hosts Sinkhole     : INACTIVE
  [ ] Wildcard DNS Routing    : INACTIVE
  [ ] nftables Firewall Table : INACTIVE
Browser Enterprise Policies:
  [✓] /etc/opt/chrome/policies/managed/domain_blocker.json
  [✓] /etc/brave/policies/managed/domain_blocker.json
  [✓] /etc/chromium/policies/managed/domain_blocker.json
  [✓] /etc/firefox/policies/policies.json
  [✓] /var/snap/firefox/common/policies/policies.json
==========================================================
```

### 2. Run Automated Verification Test
Probes loopback sanity, external DNS, target domains DNS sinkhole, and HTTP handshakes:
```bash
domain-blocker test
```

### 3. Force Immediate Synchronization
Forces the engine to evaluate current time against configured schedule and apply appropriate state:
```bash
sudo domain-blocker sync
```

### 4. Send Test Desktop Notification
Broadcasts a test notification to all active graphical login sessions:
```bash
domain-blocker notify
```

### 5. Administrative Overrides (Manual Enable / Disable)
For maintenance or troubleshooting, you can manually force states:
```bash
# Force block immediately (regardless of schedule)
sudo domain-blocker enable

# Force unblock immediately
sudo domain-blocker disable
```
*(Note: At the next scheduled timer check, `sync` will align state with the schedule unless the schedule is adjusted in `config.env`)*.

---

## Configuration Guide (`config.env`)

Configuration resides in `/etc/domain-blocker/config.env` (installed template in repository).

```bash
# ==============================================================================
# Schedule Configuration
# ==============================================================================
# Comma-separated list of time intervals in 24-hour HH:MM-HH:MM format.
# Example 1: Dual daily slots
SCHEDULE_SLOTS="07:00-11:00,18:00-22:00"

# Example 2: Standard single work-day window
# SCHEDULE_SLOTS="09:00-17:00"

# Days of the week when scheduling applies:
# Options: "all" or comma-separated "Mon,Tue,Wed,Thu,Fri"
SCHEDULE_DAYS="all"

# Pre-block warning notification in minutes (0 to disable)
PRE_BLOCK_WARN_MINUTES=2

# ==============================================================================
# Enforcement Layer Toggles (1 = Enabled, 0 = Disabled)
# ==============================================================================
ENFORCE_FIREWALL=1          # Load nftables anti-DoH and anti-DoT rules
ENFORCE_BROWSER_POLICIES=1  # Deploy Chrome/Brave/Firefox policy files
KILL_ACTIVE_SOCKETS=1       # Terminate open TCP/DoH sockets upon block start
WILDCARD_ROUTING=1          # Enable systemd-resolved wildcard routing on lo

# ==============================================================================
# Paths
# ==============================================================================
CONFIG_DIR="/etc/domain-blocker"
STATE_DIR="/run/domain-blocker"
HOSTS_FILE="/etc/hosts"
HOSTS_BACKUP="/etc/domain-blocker/hosts.original"
```

After modifying `/etc/domain-blocker/config.env`, apply changes immediately:
```bash
sudo domain-blocker sync
```

---

## Managing Target Domains & Wildcards

### Adding New Domains
Open `/etc/domain-blocker/domains.list`:
```text
# Add one domain per line:
facebook.com
www.facebook.com
twitter.com
x.com
tiktok.com
```

### Dynamic Subdomains / Wildcards
For domains that use thousands of random CDN subdomains (like YouTube's `*.googlevideo.com` or Reddit's `*.redd.it`):
1. In `domain-blocker.sh` (or `config.env`), the `apply_wildcard_routing` function binds routing domains to `lo`:
   ```bash
   resolvectl domain lo ~targetdomain.com ~targetcdn.com
   ```
2. Any DNS lookup for `sub1.sub2.targetdomain.com` is automatically matched by `systemd-resolved` and sinkholed, without needing to list every individual subdomain.

---

## Automated Verification & Diagnostics

A dedicated 35-test automated test suite is included in the project:

```bash
cd /home/pham/domain-blocker
./test_domain_blocker.sh
```

### What It Tests:
- **Suite 1:** Asset existence and JSON syntax validation (`chromium_doh.json`, `firefox_policies.json`).
- **Suite 2:** Target domain registration (`youtube.com`, `reddit.com`, `quora.com`, `use-application-dns.net`, `googlevideo.com`).
- **Suite 3:** Systemd unit and timer syntax validation (`systemd-analyze verify`).
- **Suite 4:** Schedule evaluator time simulation across boundaries (`06:59`, `07:00`, `10:59`, `11:00`, `17:59`, `18:00`, `21:59`, `22:00`).
- **Suite 5:** 2-minute pre-block warning window calculations (`06:58`, `17:58`).
- **Suite 6:** Local loopback ping and live DNS query verification.

---

## Uninstallation & Clean Rollback

To completely remove Domain Blocker and restore all original system settings:

```bash
cd /home/pham/domain-blocker
sudo ./uninstall.sh
```

### What `uninstall.sh` Restores:
1. Stops and disables `domain-blocker.timer` and `domain-blocker.service`.
2. Removes systemd service files and reloads systemd.
3. Removes hooks from `/lib/systemd/system-sleep/` and `/etc/NetworkManager/dispatcher.d/`.
4. Restores `/etc/hosts` from pristine backup `/etc/domain-blocker/hosts.original`.
5. Removes the `domain_blocker` table in `nftables`.
6. Clears wildcard routing domains and dummy DNS from `lo`.
7. Flushes `systemd-resolved` caches.
8. Removes installed browser policy files.
9. Deletes `/usr/local/bin/domain-blocker`, `/etc/domain-blocker/`, and `/run/domain-blocker/`.

---

## Troubleshooting & Verification Checklist

### 1. How do I verify browser policies are active?
- **Google Chrome / Brave / Chromium:**
  Navigate to `chrome://policy` (or `brave://policy`). Verify that `DnsOverHttpsMode` is listed with value `"off"` and status `OK`.
- **Mozilla Firefox:**
  Navigate to `about:policies`. Verify that `DNSOverHTTPS` is listed with `Enabled: false` and `Locked: true`.

### 2. How do I check if the systemd timer is running?
```bash
systemctl list-timers | grep domain-blocker
```
To view live execution logs:
```bash
journalctl -u domain-blocker.service -f
```

### 3. How do I inspect active nftables rules?
```bash
sudo nft list table inet domain_blocker
```
When blocking is active, this displays the `doh_ipv4` and `doh_ipv6` sets and the output filter rules. When blocking is inactive, the table does not exist.

### 4. What if a VPN client overrides DNS?
Because our `nftables` output chain operates at the kernel network level, it intercepts packets routed out of `tun0`, `wg0`, or any physical interface. The NetworkManager dispatcher script `/etc/NetworkManager/dispatcher.d/99-domain-blocker` automatically re-applies routing domain bindings whenever an interface connects or reconnects.

---

## Migration & Portability Guide (Other Distros)

When moving this project to another Linux machine or distribution:

### 1. Debian / Linux Mint / Pop!_OS
- Identical to Ubuntu. Ensure `systemd-resolved` is enabled:
  ```bash
  sudo systemctl enable --now systemd-resolved
  ```

### 2. Fedora / Red Hat Enterprise Linux (RHEL)
- Fedora uses `systemd-resolved` by default.
- Browser policy paths are identical (`/etc/opt/chrome/policies/managed/`, `/etc/firefox/policies/`).
- If SELinux is in `Enforcing` mode, verify permissions on scripts in `/usr/local/bin`:
  ```bash
  sudo restorecon -v /usr/local/bin/domain-blocker
  ```

### 3. Arch Linux
- Install packages: `sudo pacman -S nftables systemd iptables iproute2`
- Ensure `systemd-resolved` is active:
  ```bash
  sudo systemctl enable --now systemd-resolved
  ```
- Run `sudo ./install.sh`.

### 4. Environments Without `systemd-resolved` (e.g. standalone `dnsmasq`)
If running a distribution where `dnsmasq` serves local DNS instead of `systemd-resolved`:
1. In `config.env`, set `WILDCARD_ROUTING=0`.
2. Add a dnsmasq configuration drop-in `/etc/dnsmasq.d/domain-blocker.conf`:
   ```
   address=/youtube.com/0.0.0.0
   address=/googlevideo.com/0.0.0.0
   address=/reddit.com/0.0.0.0
   address=/quora.com/0.0.0.0
   ```
3. In `domain-blocker.sh`, replace `resolvectl domain lo` calls with creating/removing the dnsmasq drop-in and running `systemctl reload dnsmasq`.
