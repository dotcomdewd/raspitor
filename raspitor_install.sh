#!/usr/bin/env bash
set -euo pipefail

# RasTor install script based on Know How... episode 301 "Raspberry Pi TOR"
# - Installs/configures Tor transparent proxying
# - Adds iptables NAT redirects for AP clients -> Tor
# - Persists firewall rules across reboot
# - Optional: installs a local console dashboard (great for small TFTs)

# Defaults taken from the episode notes:
#  - Tor TransPort 9040
#  - Tor DNSPort 53
#  - Trans/DNS listen address 192.168.42.1
#  - Redirect rules applied on wlan0
AP_IFACE="wlan0"
AP_IP="192.168.42.1"
TOR_TRANSPORT="9040"
TOR_DNSPORT="53"
TOR_LOG="/var/log/tor/notices.log"

DO_INSTALL_HOTSPOT="no"
DO_RASPIAP_ONLY="no"
DO_DASHBOARD="no"

usage() {
  cat <<EOF
Usage:
  sudo bash $0 [--raspiap] [--install-hotspot] [--ap-iface wlan0] [--ap-ip 192.168.42.1] [--enable-dashboard]

Modes:
  --raspiap          Tor + routing only (assumes RaspiAP already provides the hotspot)
  --install-hotspot  Also installs hotspot using the unixabg RPI-Wireless-Hotspot installer (per episode)

Options:
  --ap-iface IFACE   Interface that AP clients connect to (default: wlan0)
  --ap-ip IP         The AP gateway IP on that interface (default: 192.168.42.1)
  --enable-dashboard Installs nyx/vnstat/htop/tmux and auto-launches a console dashboard on TTY1

Notes:
  - If you're using RaspiAP, you probably want: --raspiap --ap-ip <your RaspiAP gateway IP>
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-hotspot) DO_INSTALL_HOTSPOT="yes"; shift ;;
    --raspiap) DO_RASPIAP_ONLY="yes"; shift ;;
    --ap-iface) AP_IFACE="${2:-}"; shift 2 ;;
    --ap-ip) AP_IP="${2:-}"; shift 2 ;;
    --enable-dashboard) DO_DASHBOARD="yes"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

if [[ "$EUID" -ne 0 ]]; then
  echo "Please run as root: sudo bash $0 ..."
  exit 1
fi

echo "[*] Starting RasTor setup"
echo "    AP_IFACE=$AP_IFACE"
echo "    AP_IP=$AP_IP"
echo "    install_hotspot=$DO_INSTALL_HOTSPOT, raspiap_only=$DO_RASPIAP_ONLY, dashboard=$DO_DASHBOARD"
echo

# --- Preflight ---
command -v apt-get >/dev/null || { echo "apt-get not found. Are you on Raspberry Pi OS (Debian-based)?"; exit 1; }

# Enable kernel IP forwarding (common requirement for AP routing)
echo "[*] Enabling IPv4 forwarding"
sed -i 's/^\s*#\?\s*net.ipv4.ip_forward\s*=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf || true
sysctl -w net.ipv4.ip_forward=1 >/dev/null

# --- Optional hotspot install (per episode notes) ---
if [[ "$DO_INSTALL_HOTSPOT" == "yes" ]]; then
  echo "[*] Installing WiFi hotspot using unixabg/RPI-Wireless-Hotspot (as referenced in the episode)"
  apt-get update
  apt-get install -y git

  # The episode uses: git clone https://github.com/unixabg/RPI-Wireless-Hotspot.git && sudo ./install
  # This script is interactive; we launch it and you’ll answer prompts.
  if [[ ! -d /opt/RPI-Wireless-Hotspot ]]; then
    git clone https://github.com/unixabg/RPI-Wireless-Hotspot.git /opt/RPI-Wireless-Hotspot
  else
    (cd /opt/RPI-Wireless-Hotspot && git pull) || true
  fi

  echo
  echo "=== Hotspot installer is interactive (per the show’s steps). ==="
  echo "When asked, the show suggests:"
  echo "  - agree to terms: Y"
  echo "  - use preconfigured DNS: Y"
  echo "  - Unblock-Us DNS: Y"
  echo "  - WiFi defaults: N"
  echo "  - rtl871x chipset?: N"
  echo "  - chromecast support?: N"
  echo "==============================================================="
  echo

  (cd /opt/RPI-Wireless-Hotspot && bash ./install)
  echo "[*] Hotspot installer finished (it may reboot depending on your answers)"
fi

# --- Install Tor (episode step) ---
echo "[*] Installing Tor + iptables persistence tooling"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y tor iptables-persistent

# --- Configure Tor (episode config block) ---
echo "[*] Configuring /etc/tor/torrc for transparent proxying"
TORRC="/etc/tor/torrc"
cp -a "$TORRC" "${TORRC}.bak.$(date +%Y%m%d-%H%M%S)"

# Remove any prior RasTor block to keep re-runs clean
perl -0777 -i -pe 's/\n?# BEGIN RASTOR.*?# END RASTOR\n?//sg' "$TORRC"

cat >> "$TORRC" <<EOF

# BEGIN RASTOR
# Transparent proxy config based on Know How... 301 "Raspberry Pi TOR"
Log notice file $TOR_LOG
VirtualAddrNetwork 10.192.0.0/10
AutomapHostsSuffixes .onion,.exit
AutomapHostsOnResolve 1
TransPort $TOR_TRANSPORT
TransListenAddress $AP_IP
DNSPort $TOR_DNSPORT
DNSListenAddress $AP_IP
# END RASTOR
EOF

# --- Tor log file permissions (episode steps) ---
echo "[*] Creating Tor notices log at $TOR_LOG"
install -o debian-tor -g debian-tor -m 0644 /dev/null "$TOR_LOG" || true
chown debian-tor:debian-tor "$TOR_LOG"
chmod 0644 "$TOR_LOG"

# --- iptables rules (episode steps) ---
echo "[*] Applying iptables NAT redirects for AP clients -> Tor"
iptables -F
iptables -t nat -F

# Route DNS from AP clients into Tor's DNSPort
iptables -t nat -A PREROUTING -i "$AP_IFACE" -p udp --dport 53 -j REDIRECT --to-ports "$TOR_DNSPORT"

# Route TCP SYN from AP clients into Tor's TransPort
iptables -t nat -A PREROUTING -i "$AP_IFACE" -p tcp --syn -j REDIRECT --to-ports "$TOR_TRANSPORT"

echo "[*] Current NAT table:"
iptables -t nat -L -n

# Persist rules across reboot (episode saves to /etc/iptables.ipv4.nat; modern approach via iptables-persistent)
echo "[*] Saving iptables rules (iptables-persistent)"
netfilter-persistent save

# --- Enable/start Tor service (episode steps) ---
echo "[*] Enabling + restarting Tor"
systemctl enable tor
systemctl restart tor
systemctl --no-pager --full status tor || true

# --- Optional dashboard for a 3.5" local screen (console based) ---
if [[ "$DO_DASHBOARD" == "yes" ]]; then
  echo "[*] Installing console dashboard tools (nyx, vnstat, htop, tmux)"
  apt-get install -y nyx vnstat htop tmux

  systemctl enable vnstat
  systemctl restart vnstat || true

  DASHBIN="/usr/local/bin/rastor-dashboard.sh"
  cat > "$DASHBIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Simple console dashboard: Tor status + Tor traffic (nyx) + system stats.
# Intended for local display on small TFTs that mirror the console.
SESSION="rastor"

if command -v tmux >/dev/null; then
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux new-session -d -s "$SESSION" "bash -lc 'clear; echo RasTor Dashboard; echo; echo \"Top: system\"; sleep 1; htop'"
    tmux split-window -h -t "$SESSION" "bash -lc 'clear; echo Tor monitor (nyx); echo; nyx'"
    tmux split-window -v -t "$SESSION:0.1" "bash -lc 'clear; echo Network usage (vnstat); echo; watch -n 2 vnstat -l'"
    tmux select-layout -t "$SESSION" tiled >/dev/null
  fi
  exec tmux attach -t "$SESSION"
else
  echo "tmux not installed."
  exit 1
fi
EOF
  chmod +x "$DASHBIN"

  # systemd service to start dashboard on tty1 (local screen)
  DASH_SVC="/etc/systemd/system/rastor-dashboard.service"
  cat > "$DASH_SVC" <<EOF
[Unit]
Description=RasTor local console dashboard (TTY1)
After=multi-user.target

[Service]
Type=simple
ExecStart=/bin/bash -lc 'openvt -f -c 1 -- /usr/local/bin/rastor-dashboard.sh'
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable rastor-dashboard.service
  systemctl restart rastor-dashboard.service || true
  echo "[*] Dashboard enabled (TTY1). If your 3.5\" screen mirrors the console framebuffer, you'll see it there."
fi

echo
echo "[✓] Done."
echo "Next checks:"
echo "  1) Confirm AP gateway IP matches: ip -brief addr show $AP_IFACE"
echo "  2) From a client connected to the AP, browse to a Tor check site and confirm you're on Tor."
echo "  3) If clients have no DNS, verify RaspiAP/hotspot is really serving clients on $AP_IFACE and that Tor is listening on $AP_IP."
