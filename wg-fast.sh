#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root."
  exit 1
fi

if [[ ! -f /etc/os-release ]]; then
  echo "Cannot detect OS."
  exit 1
fi

. /etc/os-release

if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "22.04" ]]; then
  echo "This script is made for Ubuntu 22.04 only."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

CLIENT_NAME="${1:-client1}"
WG_IF="wg0"
WG_DIR="/etc/wireguard"
CLIENT_DIR="${WG_DIR}/clients"
WG_SUBNET="10.66.66.0/24"
SERVER_WG_IP="10.66.66.1/24"
CLIENT_WG_IP="10.66.66.2/32"
CLIENT_WG_IP_PLAIN="10.66.66.2"
MTU_VALUE="1380"

log() {
  printf '\n[+] %s\n' "$1"
}

warn() {
  printf '\n[!] %s\n' "$1"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

get_main_iface() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

get_public_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}'
}

pick_random_port() {
  while :; do
    p="$(shuf -i 20000-59999 -n 1)"
    [[ "$p" != "22" ]] || continue
    if ! ss -H -lun | awk '{print $5}' | grep -qE "[:.]${p}$"; then
      echo "$p"
      return
    fi
  done
}

setup_dns() {
  log "Setting /etc/resolv.conf to 1.1.1.1 and 8.8.8.8"

  chattr -i /etc/resolv.conf >/dev/null 2>&1 || true
  rm -f /etc/resolv.conf

  cat > /etc/resolv.conf <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
options timeout:2 attempts:2 rotate
EOF

  chmod 644 /etc/resolv.conf

  if need_cmd chattr; then
    chattr +i /etc/resolv.conf >/dev/null 2>&1 || warn "Could not make /etc/resolv.conf immutable on this filesystem."
  else
    warn "chattr not found yet; resolv.conf written but not immutable yet."
  fi
}

setup_ubuntu_sources() {
  log "Setting Ubuntu APT sources to official archive"

  mkdir -p /etc/apt/backup-chatgpt-wg
  [[ -f /etc/apt/sources.list ]] && cp -f /etc/apt/sources.list /etc/apt/backup-chatgpt-wg/sources.list.bak || true
  [[ -f /etc/apt/sources.list.d/ubuntu.sources ]] && cp -f /etc/apt/sources.list.d/ubuntu.sources /etc/apt/backup-chatgpt-wg/ubuntu.sources.bak || true

  cat > /etc/apt/sources.list <<'EOF'
deb http://archive.ubuntu.com/ubuntu jammy main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu jammy-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu jammy-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu jammy-security main restricted universe multiverse
EOF

  if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
    mv /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list.d/ubuntu.sources.disabled-by-wg-script
  fi
}

install_packages() {
  log "Updating apt cache"
  apt-get update -y

  log "Installing prerequisites"
  apt-get install -y \
    wireguard \
    wireguard-tools \
    qrencode \
    iptables \
    iproute2 \
    net-tools \
    curl \
    ca-certificates \
    openssl \
    resolvconf \
    ufw \
    e2fsprogs
}

enable_ip_forward() {
  log "Enabling IPv4 forwarding"

  cat > /etc/sysctl.d/99-wireguard-forward.conf <<'EOF'
net.ipv4.ip_forward=1
EOF

  sysctl --system >/dev/null
}

enable_bbr() {
  log "Enabling fq + BBR for better TCP throughput through the tunnel"

  cat > /etc/sysctl.d/99-wireguard-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

  sysctl --system >/dev/null || true
}

generate_wireguard() {
  log "Generating WireGuard server and client config"

  mkdir -p "${WG_DIR}" "${CLIENT_DIR}"
  chmod 700 "${WG_DIR}" "${CLIENT_DIR}"
  umask 077

  SERVER_PRIVKEY="$(wg genkey)"
  SERVER_PUBKEY="$(printf '%s' "${SERVER_PRIVKEY}" | wg pubkey)"
  CLIENT_PRIVKEY="$(wg genkey)"
  CLIENT_PUBKEY="$(printf '%s' "${CLIENT_PRIVKEY}" | wg pubkey)"
  CLIENT_PSK="$(wg genpsk)"

  PUBLIC_IFACE="$(get_main_iface)"
  SERVER_PUBLIC_IP="$(get_public_ip)"
  WG_PORT="$(pick_random_port)"

  if [[ -z "${PUBLIC_IFACE}" || -z "${SERVER_PUBLIC_IP}" ]]; then
    echo "Could not detect main interface or public IPv4."
    exit 1
  fi

  SERVER_CONF="${WG_DIR}/${WG_IF}.conf"
  CLIENT_CONF="${CLIENT_DIR}/${CLIENT_NAME}.conf"

  cat > "${SERVER_CONF}" <<EOF
[Interface]
Address = ${SERVER_WG_IP}
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIVKEY}
MTU = ${MTU_VALUE}
SaveConfig = false
PostUp = iptables -I INPUT -p udp --dport ${WG_PORT} -j ACCEPT; iptables -I FORWARD -i ${WG_IF} -j ACCEPT; iptables -I FORWARD -o ${WG_IF} -j ACCEPT; iptables -t nat -I POSTROUTING -s ${WG_SUBNET} -o ${PUBLIC_IFACE} -j MASQUERADE
PostDown = iptables -D INPUT -p udp --dport ${WG_PORT} -j ACCEPT; iptables -D FORWARD -i ${WG_IF} -j ACCEPT; iptables -D FORWARD -o ${WG_IF} -j ACCEPT; iptables -t nat -D POSTROUTING -s ${WG_SUBNET} -o ${PUBLIC_IFACE} -j MASQUERADE

[Peer]
PublicKey = ${CLIENT_PUBKEY}
PresharedKey = ${CLIENT_PSK}
AllowedIPs = ${CLIENT_WG_IP}
EOF

  chmod 600 "${SERVER_CONF}"

  cat > "${CLIENT_CONF}" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIVKEY}
Address = ${CLIENT_WG_IP_PLAIN}/32
DNS = 1.1.1.1, 8.8.8.8
MTU = ${MTU_VALUE}

[Peer]
PublicKey = ${SERVER_PUBKEY}
PresharedKey = ${CLIENT_PSK}
Endpoint = ${SERVER_PUBLIC_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

  chmod 600 "${CLIENT_CONF}"

  systemctl daemon-reload
  systemctl enable "wg-quick@${WG_IF}" >/dev/null
  systemctl restart "wg-quick@${WG_IF}"

  sleep 1

  if ! systemctl is-active --quiet "wg-quick@${WG_IF}"; then
    echo "WireGuard service failed to start."
    systemctl status "wg-quick@${WG_IF}" --no-pager || true
    exit 1
  fi

  log "WireGuard server is up"
  echo "Interface: ${WG_IF}"
  echo "Server public IP: ${SERVER_PUBLIC_IP}"
  echo "Server public interface: ${PUBLIC_IFACE}"
  echo "UDP port: ${WG_PORT}"
  echo "Client config file: ${CLIENT_CONF}"

  log "Client config text"
  echo "----------------------------------------"
  cat "${CLIENT_CONF}"
  echo "----------------------------------------"

  log "Client QR code"
  qrencode -t ANSIUTF8 < "${CLIENT_CONF}" || true
}

main() {
  setup_dns
  setup_ubuntu_sources
  install_packages
  setup_dns
  enable_ip_forward
  enable_bbr
  generate_wireguard

  log "Done"
  echo "Use this file on your system:"
  echo "${CLIENT_DIR}/${CLIENT_NAME}.conf"
}

main "$@"
