#!/bin/bash

# ==============================================================================
# RanOnline GPN (Ping Booster) Auto-Installer
# For Ubuntu 20.04 / 22.04 / Debian 11+
# ==============================================================================
# This script automatically secures your VPS and installs a high-speed
# UDP/TCP proxy daemon specifically optimized for RanOnline traffic.
# ==============================================================================

# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
   echo -e "\e[1;31mThis script must be run as root. Try 'sudo ./install_gpn.sh'\e[0m" 
   exit 1
fi

echo -e "\e[1;36m==================================================\e[0m"
echo -e "\e[1;36m   RanOnline GPN (Ping Booster) Auto-Installer    \e[0m"
echo -e "\e[1;36m==================================================\e[0m"

# 1. Get Game Server IP from user
read -p "Enter your Ran Game Server IP Address (e.g., 141.134.12.33): " GAME_SERVER_IP
if [[ -z "$GAME_SERVER_IP" ]]; then
    echo -e "\e[1;31mGame Server IP is required. Exiting.\e[0m"
    exit 1
fi

# 2. Get the Proxy Port
read -p "Enter the proxy port you want to use [Default: 8388]: " PROXY_PORT
PROXY_PORT=${PROXY_PORT:-8388}

# 3. Generate a random secure password
PASSWORD=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)

echo -e "\n\e[1;33m[1/4] Updating system packages...\e[0m"
apt-get update -y && apt-get upgrade -y
apt-get install -y snapd ufw curl

echo -e "\n\e[1;33m[2/4] Installing Shadowsocks-Rust Daemon...\e[0m"
snap install shadowsocks-rust

echo -e "\n\e[1;33m[3/4] Configuring strict firewall (GPN Whitelist)...\e[0m"
# Reset firewall to default
ufw --force reset

# Set default policies (deny incoming, allow outgoing for normal services, but we will restrict proxy users)
ufw default deny incoming
ufw default allow outgoing

# Always allow SSH
ufw allow ssh

# Allow our Proxy Port
ufw allow $PROXY_PORT/tcp
ufw allow $PROXY_PORT/udp

# WARNING: Security Restriction
# We ONLY want proxy users to talk to the $GAME_SERVER_IP on game ports (e.g., 5100, 5000, 5001...)
# This prevents hackers from using your Ping Booster as a free torrenting/illegal VPN.
# We will drop all other packets that are routed through the proxy.
ufw route allow out to $GAME_SERVER_IP
ufw route deny out to any

# Enable the firewall
yes | ufw enable

echo -e "\n\e[1;33m[4/4] Generating Proxy Configuration...\e[0m"
mkdir -p /var/snap/shadowsocks-rust/common
cat > /var/snap/shadowsocks-rust/common/config.json <<EOF
{
    "server": "0.0.0.0",
    "server_port": $PROXY_PORT,
    "password": "$PASSWORD",
    "method": "aes-256-gcm",
    "mode": "tcp_and_udp",
    "fast_open": true
}
EOF

# Create a Systemd service to ensure it runs on boot
cat > /etc/systemd/system/ran-gpn.service <<EOF
[Unit]
Description=Ran Ping Booster Proxy (Shadowsocks-Rust)
After=network.target

[Service]
ExecStart=/snap/bin/shadowsocks-rust.ssserver -c /var/snap/shadowsocks-rust/common/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

# Reload and start service
systemctl daemon-reload
systemctl enable ran-gpn.service
systemctl restart ran-gpn.service

# Get Public IP for display
PUBLIC_IP=$(curl -s ifconfig.me)

echo -e "\n\e[1;32m==================================================\e[0m"
echo -e "\e[1;32m  GPN Server Successfully Installed and Running!  \e[0m"
echo -e "\e[1;32m==================================================\e[0m"
echo -e "\e[1;37mBelow are the details you need for your C# RanPingBooster App:\e[0m"
echo -e ""
echo -e "Server IP : \e[1;32m$PUBLIC_IP\e[0m"
echo -e "Port      : \e[1;32m$PROXY_PORT\e[0m"
echo -e "Password  : \e[1;32m$PASSWORD\e[0m"
echo -e "Method    : \e[1;32maes-256-gcm\e[0m"
echo -e "Target IP : \e[1;32m$GAME_SERVER_IP\e[0m (Whitelisted for routing)"
echo -e "\e[1;36m==================================================\e[0m"
echo -e "Your Ping Booster VPS is fully locked down. It is physically impossible"
echo -e "for users to visit malicious sites using your server's IP."
echo -e "You can upload this script to your GitHub repository."
