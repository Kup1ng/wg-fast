#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

WG_IF="wg0"
WG_PORT="${WG_PORT:-51820}"
SERVER_WG_IP="${SERVER_WG_IP:-10.66.66.1/24}"
CLIENT_WG_IP="${CLIENT_WG_IP:-10.66.66.2/32}"
CLIENT_NAME="${CLIENT_NAME:-client1}"
CLIENT_DNS="${CLIENT_DNS:-1.1.1.1,1.0.0.1}"
MTU="${MTU:-1420}"
KEEPALIVE="${KEEPALIVE:-25}"

SERVER_DIR="/etc/wireguard"
CLIENT_DIR="/etc/wireguard/clients/${CLIENT_NAME}"
SERVER_CONF="${SERVER_DIR}/${WG_IF}.conf"
CLIENT_CONF="${CLIENT_DIR}/${CLIENT_NAME}.conf"

msg() { echo -e "\n[+] $*\n"; }
err() { echo -e "\n[!] $*\n" >&2; }

if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "22.04" ]]; then
    err "This script is made for Ubuntu 22.04. Detected: ${PRETTY_NAME:-unknown}"
    exit 1
  fi
else
  err "/etc/os-release not found."
  exit 1
fi

msg "Installing prerequisites..."
apt-get update -y
apt-get install -y wireguard qrencode iptables iproute2 net-tools curl ca-certificates

mkdir -p "${SERVER_DIR}" "${CLIENT_DIR}"
chmod 700 "${SERVER_DIR}"
chmod 700 "${CLIENT_DIR}"

msg "Detecting primary network interface and public IP..."
PUB_NIC="$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
PUBLIC_IP="$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"

if [[ -z "${PUB_NIC}" ]]; then
  err "Could not detect public network interface."
  exit 1
fi

if [[ -z "${PUBLIC_IP}" ]]; then
  PUBLIC_IP="$(curl -4 -fsS https://icanhazip.com | tr -d '\n' || true)"
fi

if [[ -z "${PUBLIC_IP}" ]]; then
  err "Could not detect public IPv4."
  exit 1
fi

msg "Primary interface: ${PUB_NIC}"
msg "Public IPv4: ${PUBLIC_IP}"

msg "Enabling IPv4 forwarding..."
cat >/etc/sysctl.d/99-wireguard-forward.conf <<'EOF'
net.ipv4.ip_forward=1
EOF
sysctl --system >/dev/null

msg "Generating WireGuard keys..."
umask 077
SERVER_PRIVKEY="$(wg genkey)"
SERVER_PUBKEY="$(printf '%s' "${SERVER_PRIVKEY}" | wg pubkey)"
CLIENT_PRIVKEY="$(wg genkey)"
CLIENT_PUBKEY="$(printf '%s' "${CLIENT_PRIVKEY}" | wg pubkey)"

echo "${SERVER_PRIVKEY}" > "${SERVER_DIR}/server_private.key"
echo "${SERVER_PUBKEY}"  > "${SERVER_DIR}/server_public.key"
echo "${CLIENT_PRIVKEY}" > "${CLIENT_DIR}/client_private.key"
echo "${CLIENT_PUBKEY}"  > "${CLIENT_DIR}/client_public.key"

msg "Writing server config..."
cat > "${SERVER_CONF}" <<EOF
[Interface]
Address = ${SERVER_WG_IP}
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIVKEY}
SaveConfig = false

PostUp = iptables -I INPUT -p udp --dport ${WG_PORT} -j ACCEPT
PostUp = iptables -I FORWARD -i ${WG_IF} -j ACCEPT
PostUp = iptables -I FORWARD -o ${WG_IF} -j ACCEPT
PostUp = iptables -t nat -I POSTROUTING -o ${PUB_NIC} -j MASQUERADE
PostDown = iptables -D INPUT -p udp --dport ${WG_PORT} -j ACCEPT
PostDown = iptables -D FORWARD -i ${WG_IF} -j ACCEPT
PostDown = iptables -D FORWARD -o ${WG_IF} -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o ${PUB_NIC} -j MASQUERADE

[Peer]
PublicKey = ${CLIENT_PUBKEY}
AllowedIPs = ${CLIENT_WG_IP}
EOF

chmod 600 "${SERVER_CONF}"

msg "Writing client config..."
cat > "${CLIENT_CONF}" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIVKEY}
Address = ${CLIENT_WG_IP}
DNS = ${CLIENT_DNS}
MTU = ${MTU}

[Peer]
PublicKey = ${SERVER_PUBKEY}
Endpoint = ${PUBLIC_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = ${KEEPALIVE}
EOF

chmod 600 "${CLIENT_CONF}"

msg "Opening UDP port in iptables..."
iptables -C INPUT -p udp --dport "${WG_PORT}" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "${WG_PORT}" -j ACCEPT

msg "Enabling and starting WireGuard..."
systemctl enable "wg-quick@${WG_IF}" >/dev/null
systemctl restart "wg-quick@${WG_IF}"

sleep 1

msg "Server status:"
wg show "${WG_IF}" || true
ip -brief addr show "${WG_IF}" || true

echo
echo "============================================================"
echo "CLIENT CONFIG TEXT"
echo "============================================================"
cat "${CLIENT_CONF}"
echo "============================================================"
echo

echo "Client config file saved at:"
echo "${CLIENT_CONF}"
echo

echo "Server public key:"
echo "${SERVER_PUBKEY}"
echo

echo "Client public key:"
echo "${CLIENT_PUBKEY}"
echo

echo "QR CODE:"
qrencode -t ANSIUTF8 < "${CLIENT_CONF}"
echo

echo "Quick import hints:"
echo " - Windows WireGuard: Import tunnel(s) from file -> ${CLIENT_CONF}"
echo " - Mobile WireGuard: scan the QR shown above"
echo
echo "Done."
