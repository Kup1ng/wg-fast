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

if [[ "${ID:-}" != "ubuntu" ]]; then
  echo "This script is made for Ubuntu only (22.04 or 24.04)."
  exit 1
fi

case "${VERSION_ID:-}" in
  22.04)
    UBUNTU_CODENAME_DETECTED="jammy"
    ;;
  24.04)
    UBUNTU_CODENAME_DETECTED="noble"
    ;;
  *)
    echo "Unsupported Ubuntu version: ${VERSION_ID:-unknown}. Only 22.04 and 24.04 are supported."
    exit 1
    ;;
esac

echo "[+] Detected Ubuntu ${VERSION_ID} (${UBUNTU_CODENAME_DETECTED})"

export DEBIAN_FRONTEND=noninteractive

CLIENT_NAME="${1:-client1}"
WG_DIR="/etc/wireguard"
CLIENT_DIR="${WG_DIR}/clients"
MTU_VALUE="1356"

# marker line written into every server config created by this script,
# so delete/show menus can tell our instances apart from others
MANAGED_MARKER="wg-fast-managed"

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

# pick first free wgN slot (wg0, wg1, wg2, ...)
pick_free_interface() {
  local n=0
  while :; do
    local candidate="wg${n}"
    if [[ ! -f "${WG_DIR}/${candidate}.conf" ]] \
       && ! ip link show "${candidate}" >/dev/null 2>&1 \
       && ! systemctl is-enabled --quiet "wg-quick@${candidate}" 2>/dev/null \
       && ! systemctl is-active --quiet "wg-quick@${candidate}" 2>/dev/null; then
      echo "${candidate}"
      return
    fi
    n=$((n + 1))
    if [[ "${n}" -gt 50 ]]; then
      echo "Too many wireguard interfaces, aborting." >&2
      exit 1
    fi
  done
}

# return list of UDP ports used by existing wireguard configs
existing_wg_ports() {
  local f port
  for f in "${WG_DIR}"/wg*.conf; do
    [[ -f "${f}" ]] || continue
    port="$(awk -F'=' '/^[[:space:]]*ListenPort[[:space:]]*=/ {gsub(/ /,"",$2); print $2; exit}' "${f}" || true)"
    [[ -n "${port}" ]] && echo "${port}"
  done
}

pick_random_port() {
  local used_ports
  used_ports="$(existing_wg_ports || true)"
  while :; do
    p="$(shuf -i 20000-59999 -n 1)"
    [[ "$p" != "22" ]] || continue
    # skip ports already used by other wg configs
    if echo "${used_ports}" | grep -qx "${p}"; then
      continue
    fi
    if ! ss -H -lun | awk '{print $5}' | grep -qE "[:.]${p}$"; then
      echo "$p"
      return
    fi
  done
}

# return list of subnets used by existing wireguard configs (e.g. 10.22.132.0/24)
existing_wg_subnets() {
  local f addr
  for f in "${WG_DIR}"/wg*.conf; do
    [[ -f "${f}" ]] || continue
    # take first Address line (server side has like 10.x.y.1/24)
    addr="$(awk -F'=' '/^[[:space:]]*Address[[:space:]]*=/ {gsub(/ /,"",$2); print $2; exit}' "${f}" || true)"
    if [[ -n "${addr}" ]]; then
      # turn 10.22.132.1/24 into 10.22.132.0/24
      local ip cidr
      ip="${addr%/*}"
      cidr="${addr#*/}"
      IFS=. read -r o1 o2 o3 _ <<< "${ip}"
      echo "${o1}.${o2}.${o3}.0/${cidr}"
    fi
  done
}

pick_random_subnet() {
  local existing
  existing="$(existing_wg_subnets || true)"
  while :; do
    OCTET2="$(shuf -i 16-31 -n 1)"
    OCTET3="$(shuf -i 1-254 -n 1)"
    CANDIDATE_SUBNET="10.${OCTET2}.${OCTET3}.0/24"
    CANDIDATE_SERVER_IP="10.${OCTET2}.${OCTET3}.1/24"
    CANDIDATE_CLIENT_IP="10.${OCTET2}.${OCTET3}.2/32"
    CANDIDATE_CLIENT_IP_PLAIN="10.${OCTET2}.${OCTET3}.2"

    # don't reuse a subnet that another wg config already uses
    if echo "${existing}" | grep -qx "${CANDIDATE_SUBNET}"; then
      continue
    fi

    if ! ip route | grep -q "10\.${OCTET2}\.${OCTET3}\.0/24"; then
      WG_SUBNET="${CANDIDATE_SUBNET}"
      SERVER_WG_IP="${CANDIDATE_SERVER_IP}"
      CLIENT_WG_IP="${CANDIDATE_CLIENT_IP}"
      CLIENT_WG_IP_PLAIN="${CANDIDATE_CLIENT_IP_PLAIN}"
      return
    fi
  done
}

setup_dns() {
  chattr -i /etc/resolv.conf >/dev/null 2>&1 || true
  rm -f /etc/resolv.conf
  cat > /etc/resolv.conf <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
}

lock_dns() {
  chattr +i /etc/resolv.conf >/dev/null 2>&1 || true
}

setup_ubuntu_sources() {
  log "Setting Ubuntu APT sources to official archive (${UBUNTU_CODENAME_DETECTED})"

  mkdir -p /etc/apt/backup-chatgpt-wg
  [[ -f /etc/apt/sources.list ]] && cp -f /etc/apt/sources.list /etc/apt/backup-chatgpt-wg/sources.list.bak || true
  [[ -f /etc/apt/sources.list.d/ubuntu.sources ]] && cp -f /etc/apt/sources.list.d/ubuntu.sources /etc/apt/backup-chatgpt-wg/ubuntu.sources.bak || true

  if [[ "${UBUNTU_CODENAME_DETECTED}" == "jammy" ]]; then
    cat > /etc/apt/sources.list <<EOF
deb http://archive.ubuntu.com/ubuntu ${UBUNTU_CODENAME_DETECTED} main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu ${UBUNTU_CODENAME_DETECTED}-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu ${UBUNTU_CODENAME_DETECTED}-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu ${UBUNTU_CODENAME_DETECTED}-security main restricted universe multiverse
EOF

    if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
      mv /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list.d/ubuntu.sources.disabled-by-wg-script
    fi
  else
    : > /etc/apt/sources.list

    cat > /etc/apt/sources.list.d/ubuntu.sources <<EOF
Types: deb
URIs: http://archive.ubuntu.com/ubuntu/
Suites: ${UBUNTU_CODENAME_DETECTED} ${UBUNTU_CODENAME_DETECTED}-updates ${UBUNTU_CODENAME_DETECTED}-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://security.ubuntu.com/ubuntu/
Suites: ${UBUNTU_CODENAME_DETECTED}-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
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

  # pick a free wgN slot, so existing instances stay untouched
  WG_IF="$(pick_free_interface)"
  log "Using interface ${WG_IF} (existing wireguard instances are left alone)"

  pick_random_subnet

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
  # include interface name in client filename so multiple instances don't collide
  CLIENT_CONF="${CLIENT_DIR}/${CLIENT_NAME}-${WG_IF}.conf"

  cat > "${SERVER_CONF}" <<EOF
# ${MANAGED_MARKER}
# client-name = ${CLIENT_NAME}
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
  echo "Tunnel subnet: ${WG_SUBNET}"
  echo "Client config file: ${CLIENT_CONF}"

  log "Existing WireGuard instances on this server"
  systemctl list-units --type=service --all 'wg-quick@*' --no-pager --no-legend \
    | awk '{print "  - " $1 " (" $3 "/" $4 ")"}' || true

  log "Client config text"
  echo "----------------------------------------"
  cat "${CLIENT_CONF}"
  echo "----------------------------------------"

  log "Client QR code"
  qrencode -t ANSIUTF8 < "${CLIENT_CONF}" || true
}

# ---------------------------------------------------------------------------
# Management helpers (used by delete / show menus)
# ---------------------------------------------------------------------------

# is a given interface (e.g. wg0) one that this script created?
is_managed_interface() {
  local iface="$1"
  local conf="${WG_DIR}/${iface}.conf"
  [[ -f "${conf}" ]] || return 1

  # new instances carry the marker line
  if grep -q "${MANAGED_MARKER}" "${conf}" 2>/dev/null; then
    return 0
  fi

  # fallback for older instances: a matching client config exists
  local cf
  for cf in "${CLIENT_DIR}"/*-"${iface}".conf; do
    [[ -e "${cf}" ]] && return 0
  done

  return 1
}

# print the names of all managed interfaces, one per line, sorted
list_managed_interfaces() {
  local f base iface
  for f in "${WG_DIR}"/wg*.conf; do
    [[ -f "${f}" ]] || continue
    base="$(basename "${f}")"
    iface="${base%.conf}"
    if is_managed_interface "${iface}"; then
      echo "${iface}"
    fi
  done | sort -V
}

# fully remove one wg instance: stop service, drop link, delete files
remove_one_interface() {
  local iface="$1"
  log "Removing ${iface}"

  # stop first so PostDown runs (it cleans the iptables rules) while conf still exists
  systemctl stop "wg-quick@${iface}" >/dev/null 2>&1 || true
  systemctl disable "wg-quick@${iface}" >/dev/null 2>&1 || true

  # in case the link is still around
  if ip link show "${iface}" >/dev/null 2>&1; then
    ip link delete "${iface}" 2>/dev/null || true
  fi

  rm -f "${WG_DIR}/${iface}.conf"

  # remove matching client configs
  local cf
  for cf in "${CLIENT_DIR}"/*-"${iface}".conf; do
    [[ -e "${cf}" ]] || continue
    rm -f "${cf}"
    echo "  removed client config: ${cf}"
  done

  echo "  ${iface} removed."
}

# pretty one-line summary for an interface, used in menus
iface_summary() {
  local iface="$1"
  local conf="${WG_DIR}/${iface}.conf"
  local port subnet status name
  port="$(awk -F'=' '/^[[:space:]]*ListenPort/ {gsub(/ /,"",$2); print $2; exit}' "${conf}" 2>/dev/null || true)"
  subnet="$(awk -F'=' '/^[[:space:]]*Address/ {gsub(/ /,"",$2); print $2; exit}' "${conf}" 2>/dev/null || true)"
  name="$(awk -F'=' '/^#[[:space:]]*client-name/ {gsub(/ /,"",$2); print $2; exit}' "${conf}" 2>/dev/null || true)"
  if systemctl is-active --quiet "wg-quick@${iface}" 2>/dev/null; then
    status="active"
  else
    status="inactive"
  fi
  printf '%s  (client: %s, port: %s, addr: %s, %s)' \
    "${iface}" "${name:-?}" "${port:-?}" "${subnet:-?}" "${status}"
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

do_install() {
  # let the user choose a client name (default comes from $1 or "client1")
  local default_name="${CLIENT_NAME}"
  local name_input
  read -rp "Client name [${default_name}]: " name_input
  CLIENT_NAME="${name_input:-${default_name}}"
  # sanitize: no spaces or path separators in the filename
  CLIENT_NAME="${CLIENT_NAME// /_}"
  CLIENT_NAME="${CLIENT_NAME//\//_}"
  [[ -z "${CLIENT_NAME}" ]] && CLIENT_NAME="${default_name}"

  setup_dns
  lock_dns
  setup_ubuntu_sources
  install_packages
  enable_ip_forward
  enable_bbr
  generate_wireguard

  log "Done"
  echo "Use this file on your client device:"
  echo "${CLIENT_CONF}"
}

do_delete() {
  log "Delete WireGuard instance(s)"

  local ifaces=()
  mapfile -t ifaces < <(list_managed_interfaces)

  if [[ "${#ifaces[@]}" -eq 0 ]]; then
    warn "No WireGuard instances created by this script were found."
    return
  fi

  echo "Existing WireGuard instances:"
  local i
  for i in "${!ifaces[@]}"; do
    printf "  %d) %s\n" "$((i + 1))" "$(iface_summary "${ifaces[$i]}")"
  done
  printf "  a) all of the above\n"
  printf "  q) cancel\n"

  local choice
  read -rp "Select instance to delete [number / a / q]: " choice

  local to_delete=()
  case "${choice}" in
    q|Q|"")
      warn "Cancelled."
      return
      ;;
    a|A|all|ALL)
      to_delete=("${ifaces[@]}")
      ;;
    *)
      if [[ "${choice}" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#ifaces[@]} )); then
        to_delete=("${ifaces[$((choice - 1))]}")
      else
        warn "Invalid selection."
        return
      fi
      ;;
  esac

  echo
  echo "About to delete: ${to_delete[*]}"
  local confirm
  read -rp "Are you sure? This stops the tunnel(s) and removes their files [y/N]: " confirm
  if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
    warn "Cancelled."
    return
  fi

  local iface
  for iface in "${to_delete[@]}"; do
    remove_one_interface "${iface}"
  done

  systemctl daemon-reload >/dev/null 2>&1 || true
  log "Deletion complete."
}

do_show() {
  log "Show WireGuard client config"

  local ifaces=()
  mapfile -t ifaces < <(list_managed_interfaces)

  if [[ "${#ifaces[@]}" -eq 0 ]]; then
    warn "No WireGuard instances created by this script were found."
    return
  fi

  echo "Existing WireGuard instances:"
  local i
  for i in "${!ifaces[@]}"; do
    printf "  %d) %s\n" "$((i + 1))" "$(iface_summary "${ifaces[$i]}")"
  done
  printf "  q) cancel\n"

  local choice
  read -rp "Select instance to show [number / q]: " choice
  if [[ "${choice}" =~ ^[Qq]$ || -z "${choice}" ]]; then
    warn "Cancelled."
    return
  fi
  if ! [[ "${choice}" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#ifaces[@]} )); then
    warn "Invalid selection."
    return
  fi

  local iface="${ifaces[$((choice - 1))]}"

  # collect client config file(s) belonging to this interface
  local clients=()
  local cf
  for cf in "${CLIENT_DIR}"/*-"${iface}".conf; do
    [[ -e "${cf}" ]] && clients+=("${cf}")
  done

  if [[ "${#clients[@]}" -eq 0 ]]; then
    warn "No client config file found for ${iface} in ${CLIENT_DIR}."
    return
  fi

  local target
  if [[ "${#clients[@]}" -eq 1 ]]; then
    target="${clients[0]}"
  else
    echo "Multiple client configs for ${iface}:"
    for i in "${!clients[@]}"; do
      printf "  %d) %s\n" "$((i + 1))" "$(basename "${clients[$i]}")"
    done
    local c2
    read -rp "Select client config [number]: " c2
    if ! [[ "${c2}" =~ ^[0-9]+$ ]] || (( c2 < 1 || c2 > ${#clients[@]} )); then
      warn "Invalid selection."
      return
    fi
    target="${clients[$((c2 - 1))]}"
  fi

  log "Client config: ${target}"
  echo "----------------------------------------"
  cat "${target}"
  echo "----------------------------------------"

  if need_cmd qrencode; then
    log "QR code"
    qrencode -t ANSIUTF8 < "${target}" || true
  else
    warn "qrencode is not installed; cannot render the QR code."
    echo "Install it with: apt-get install -y qrencode"
  fi
}

# ---------------------------------------------------------------------------
# Menu / entry point
# ---------------------------------------------------------------------------

main_menu() {
  echo
  echo "================ wg-fast ================"
  echo "  1) Install / create a new WireGuard"
  echo "  2) Delete an existing WireGuard"
  echo "  3) Show a WireGuard config (text + QR)"
  echo "  q) Quit"
  echo "========================================="
  local action
  read -rp "Choose an option [1/2/3/q]: " action
  case "${action}" in
    1) do_install ;;
    2) do_delete ;;
    3) do_show ;;
    q|Q|"") log "Bye."; exit 0 ;;
    *) warn "Invalid option."; exit 1 ;;
  esac
}

main() {
  main_menu
}

main "$@"
