#!/bin/bash

# ==============================================================================
# RanOnline GRE Entry VPS Auto-Installer
# Ubuntu 22.04 / Debian 11+
# ==============================================================================
# What this does:
# - Sets up a GRE tunnel on the VPS
# - Enables IPv4 forwarding
# - Forwards selected TCP/UDP game ports to your backend through GRE
# - Preserves the real player IP (NO SNAT/MASQUERADE on forwarded game traffic)
# - Locks down firewall rules
# - Persists config across reboot
# ==============================================================================

set -e

if [[ $EUID -ne 0 ]]; then
   echo -e "\e[1;31mThis script must be run as root. Try: sudo ./install_gre_gpn.sh\e[0m"
   exit 1
fi

echo -e "\e[1;36m=========================================================\e[0m"
echo -e "\e[1;36m   RanOnline GRE Entry VPS Auto-Installer (Ubuntu)       \e[0m"
echo -e "\e[1;36m=========================================================\e[0m"

# ------------------------------------------------------------------------------
# INPUTS
# ------------------------------------------------------------------------------

read -p "Enter VPS public IPv4 (this Ubuntu server public IP): " VPS_PUBLIC_IP
if [[ -z "$VPS_PUBLIC_IP" ]]; then
    echo -e "\e[1;31mVPS public IP is required. Exiting.\e[0m"
    exit 1
fi

read -p "Enter BACKEND public IPv4 (your OVH/backend public IP): " BACKEND_PUBLIC_IP
if [[ -z "$BACKEND_PUBLIC_IP" ]]; then
    echo -e "\e[1;31mBackend public IP is required. Exiting.\e[0m"
    exit 1
fi

read -p "Enter GRE tunnel local IP for VPS [Default: 10.99.99.1]: " GRE_LOCAL_IP
GRE_LOCAL_IP=${GRE_LOCAL_IP:-10.99.99.1}

read -p "Enter GRE tunnel remote IP for backend [Default: 10.99.99.2]: " GRE_REMOTE_IP
GRE_REMOTE_IP=${GRE_REMOTE_IP:-10.99.99.2}

read -p "Enter GRE tunnel interface name [Default: gre1]: " GRE_IF
GRE_IF=${GRE_IF:-gre1}

echo ""
echo "Enter the public game ports players will connect to on this VPS."
echo "Examples:"
echo "  TCP ports: 43594,5000,5001"
echo "  UDP ports: 43594,5000,5001"
echo ""

read -p "Enter TCP ports to forward (comma-separated, leave blank if none): " TCP_PORTS
read -p "Enter UDP ports to forward (comma-separated, leave blank if none): " UDP_PORTS

if [[ -z "$TCP_PORTS" && -z "$UDP_PORTS" ]]; then
    echo -e "\e[1;31mAt least one TCP or UDP port is required. Exiting.\e[0m"
    exit 1
fi

read -p "Enter SSH port to allow [Default: 22]: " SSH_PORT
SSH_PORT=${SSH_PORT:-22}

# ------------------------------------------------------------------------------
# PREP
# ------------------------------------------------------------------------------

echo -e "\n\e[1;33m[1/7] Installing required packages...\e[0m"
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    iproute2 iptables iptables-persistent netfilter-persistent curl

# ------------------------------------------------------------------------------
# SYSCTL
# ------------------------------------------------------------------------------

echo -e "\n\e[1;33m[2/7] Enabling IPv4 forwarding and sane tunnel settings...\e[0m"

cat > /etc/sysctl.d/99-ran-gre.conf <<EOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
EOF

sysctl --system >/dev/null

# ------------------------------------------------------------------------------
# GRE SETUP SCRIPT
# ------------------------------------------------------------------------------

echo -e "\n\e[1;33m[3/7] Creating persistent GRE setup script...\e[0m"

mkdir -p /opt/ran-gre

cat > /opt/ran-gre/setup-gre.sh <<EOF
#!/bin/bash
set -e

GRE_IF="${GRE_IF}"
VPS_PUBLIC_IP="${VPS_PUBLIC_IP}"
BACKEND_PUBLIC_IP="${BACKEND_PUBLIC_IP}"
GRE_LOCAL_IP="${GRE_LOCAL_IP}"
GRE_REMOTE_IP="${GRE_REMOTE_IP}"

ip tunnel del "\$GRE_IF" 2>/dev/null || true
ip tunnel add "\$GRE_IF" mode gre local "\$VPS_PUBLIC_IP" remote "\$BACKEND_PUBLIC_IP" ttl 255
ip addr flush dev "\$GRE_IF" 2>/dev/null || true
ip addr add "\$GRE_LOCAL_IP/30" dev "\$GRE_IF"
ip link set "\$GRE_IF" up

# Make sure route to tunnel peer exists
ip route replace "\$GRE_REMOTE_IP/32" dev "\$GRE_IF"
EOF

chmod +x /opt/ran-gre/setup-gre.sh

# ------------------------------------------------------------------------------
# FIREWALL / IPTABLES
# ------------------------------------------------------------------------------

echo -e "\n\e[1;33m[4/7] Applying firewall and forwarding rules...\e[0m"

iptables -F
iptables -t nat -F
iptables -t mangle -F
iptables -X

# Default policies
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# Allow loopback + established
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow SSH
iptables -A INPUT -p tcp --dport "${SSH_PORT}" -j ACCEPT

# Allow GRE from backend only
iptables -A INPUT -p 47 -s "${BACKEND_PUBLIC_IP}" -d "${VPS_PUBLIC_IP}" -j ACCEPT
iptables -A OUTPUT -p 47 -s "${VPS_PUBLIC_IP}" -d "${BACKEND_PUBLIC_IP}" -j ACCEPT

# Allow ICMP for troubleshooting
iptables -A INPUT -p icmp -j ACCEPT
iptables -A FORWARD -p icmp -j ACCEPT

# Function to trim spaces
trim() {
    echo "$1" | xargs
}

# TCP forward rules
IFS=',' read -ra TCP_ARRAY <<< "${TCP_PORTS}"
for port in "${TCP_ARRAY[@]}"; do
    port=$(trim "$port")
    [[ -z "$port" ]] && continue

    # Allow player traffic in
    iptables -A INPUT -p tcp --dport "$port" -j ACCEPT

    # DNAT to backend GRE IP
    iptables -t nat -A PREROUTING -p tcp -d "${VPS_PUBLIC_IP}" --dport "$port" -j DNAT --to-destination "${GRE_REMOTE_IP}:$port"

    # Forward through GRE
    iptables -A FORWARD -p tcp -d "${GRE_REMOTE_IP}" --dport "$port" -j ACCEPT
done

# UDP forward rules
IFS=',' read -ra UDP_ARRAY <<< "${UDP_PORTS}"
for port in "${UDP_ARRAY[@]}"; do
    port=$(trim "$port")
    [[ -z "$port" ]] && continue

    # Allow player traffic in
    iptables -A INPUT -p udp --dport "$port" -j ACCEPT

    # DNAT to backend GRE IP
    iptables -t nat -A PREROUTING -p udp -d "${VPS_PUBLIC_IP}" --dport "$port" -j DNAT --to-destination "${GRE_REMOTE_IP}:$port"

    # Forward through GRE
    iptables -A FORWARD -p udp -d "${GRE_REMOTE_IP}" --dport "$port" -j ACCEPT
done

# IMPORTANT:
# NO POSTROUTING MASQUERADE/SNAT for forwarded game traffic.
# This preserves the real client IP for the backend server.

# Save rules
netfilter-persistent save >/dev/null

# ------------------------------------------------------------------------------
# SYSTEMD SERVICE
# ------------------------------------------------------------------------------

echo -e "\n\e[1;33m[5/7] Creating systemd service for GRE tunnel...\e[0m"

cat > /etc/systemd/system/ran-gre.service <<EOF
[Unit]
Description=RanOnline GRE Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/ran-gre/setup-gre.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ran-gre.service
systemctl restart ran-gre.service

# ------------------------------------------------------------------------------
# REAPPLY IPTABLES ON BOOT
# ------------------------------------------------------------------------------

echo -e "\n\e[1;33m[6/7] Ensuring firewall rules persist after reboot...\e[0m"
systemctl enable netfilter-persistent
systemctl restart netfilter-persistent

# ------------------------------------------------------------------------------
# OUTPUT
# ------------------------------------------------------------------------------

echo -e "\n\e[1;33m[7/7] Gathering final info...\e[0m"

PUBLIC_IP4=$(curl -4 -s ifconfig.me || curl -4 -s ifconfig.co || true)
if [[ -z "$PUBLIC_IP4" ]]; then
    PUBLIC_IP4="${VPS_PUBLIC_IP}"
fi

echo -e "\n\e[1;32m=========================================================\e[0m"
echo -e "\e[1;32m      GRE Entry VPS Installed Successfully               \e[0m"
echo -e "\e[1;32m=========================================================\e[0m"
echo -e "Public VPS IP     : \e[1;32m$PUBLIC_IP4\e[0m"
echo -e "Backend Public IP : \e[1;32m$BACKEND_PUBLIC_IP\e[0m"
echo -e "GRE Interface     : \e[1;32m$GRE_IF\e[0m"
echo -e "GRE Local IP      : \e[1;32m$GRE_LOCAL_IP\e[0m"
echo -e "GRE Remote IP     : \e[1;32m$GRE_REMOTE_IP\e[0m"
echo -e "TCP Ports         : \e[1;32m${TCP_PORTS:-None}\e[0m"
echo -e "UDP Ports         : \e[1;32m${UDP_PORTS:-None}\e[0m"
echo -e "SSH Port Allowed  : \e[1;32m$SSH_PORT\e[0m"
echo -e "\e[1;36m=========================================================\e[0m"
echo -e "Players should connect to the VPS public IP above."
echo -e ""
echo -e "\e[1;33mIMPORTANT BACKEND REMINDERS:\e[0m"
echo -e "1. Your backend must also create the GRE tunnel."
echo -e "2. Backend GRE IP should be: $GRE_REMOTE_IP/30"
echo -e "3. Backend must route replies back through GRE."
echo -e "4. Your game service must listen on the backend/tunnel path correctly."
echo -e "5. Do NOT enable SNAT/MASQUERADE for forwarded game traffic."
echo -e "\e[1;36m=========================================================\e[0m"