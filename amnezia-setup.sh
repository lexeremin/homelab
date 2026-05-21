#!/bin/bash
# ══════════════════════════════════════════════════════════════════
#  amnezia-setup.sh — AmneziaWG server + client manager
# ══════════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# ── Load .env ─────────────────────────────────────────────────────
[[ -f "$ENV_FILE" ]] || {
  echo "✗ .env not found — copy .env.example → .env and fill in your values."
  exit 1
}
set -a; source "$ENV_FILE"; set +a

# ── Helpers ───────────────────────────────────────────────────────
die()     { echo "✗ $*" >&2; exit 1; }
step()    { echo ""; echo "▶ $*"; }
info()    { echo "  $*"; }
confirm() { read -rp "  $* [y/N] " r; [[ "${r,,}" == "y" ]]; }

need() { command -v "$1" &>/dev/null || die "'$1' not found — $2"; }

# ── Docker wrapper (auto-detects if sudo is needed) ───────────────
if docker info &>/dev/null 2>&1; then
  DOCKER="docker"
elif sudo docker info &>/dev/null 2>&1; then
  DOCKER="sudo docker"
else
  die "Docker not reachable. Install Docker or add user to docker group."
fi

# ── AmneziaWG key generation (via container, no wireguard-tools needed) ──
awg_run()     { $DOCKER run --rm "${IMAGE}" awg "$@"; }
gen_privkey() { awg_run genkey; }
gen_pubkey()  { echo "$1" | $DOCKER run --rm -i "${IMAGE}" awg pubkey; }
gen_psk()     { awg_run genpsk; }

env_set() {
  local key="$1" val="$2"
  if grep -q "^${key}=" "$ENV_FILE"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
  else
    echo "${key}=${val}" >> "$ENV_FILE"
  fi
}

rand32() { od -An -tu4 -N4 /dev/urandom | tr -d ' \n'; }

gen_h_values() {
  H1=$(rand32)
  H2=$(rand32); while [[ "$H2" == "$H1" ]]; do H2=$(rand32); done
  H3=$(rand32); while [[ "$H3" == "$H1" || "$H3" == "$H2" ]]; do H3=$(rand32); done
  H4=$(rand32); while [[ "$H4" == "$H1" || "$H4" == "$H2" || "$H4" == "$H3" ]]; do H4=$(rand32); done
  export H1 H2 H3 H4
}

conf_get() { sudo grep "^${1} = " "${CONFIG_DIR}/awg0.conf" | head -1 | awk '{print $3}'; }

next_client_ip() {
  local last=0 n
  while read -r n; do
    [[ "$n" -gt "$last" ]] && last="$n"
  done < <(sudo grep "^AllowedIPs = ${VPN_PREFIX}\." "${CONFIG_DIR}/awg0.conf" \
            | grep -oP "\.\K[0-9]+(?=/32)" || true)
  echo "$((last + 1))"
}

list_clients() {
  sudo grep "^# Client: " "${CONFIG_DIR}/awg0.conf" | sed 's/^# Client: //' || true
}

client_pubkey() {
  local name="$1"
  sudo awk "/^# Client: ${name}$/{found=1} found && /^PublicKey/{print \$3; exit}" \
    "${CONFIG_DIR}/awg0.conf"
}

remove_client_block() {
  local name="$1"
  sudo python3 - << EOF
import re

with open("${CONFIG_DIR}/awg0.conf", "r") as f:
    content = f.read()

pattern = r'\n+# Client: ${name}\n\[Peer\](?:[^\[]*)'
content = re.sub(pattern, '', content)

with open("${CONFIG_DIR}/awg0.conf", "w") as f:
    f.write(content)
EOF
}

is_setup()   { sudo test -f "${CONFIG_DIR}/awg0.conf"; }
is_running() {
  [[ "$($DOCKER inspect -f '{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null)" == "running" ]]
}

# ══════════════════════════════════════════════════════════════════
menu_setup() {
  is_setup && { echo "  Server already set up. Run 'remove setup' first to reset."; return; }
  need docker "https://docs.docker.com/engine/install/"

  step "Pulling image: ${IMAGE}"
  $DOCKER pull "${IMAGE}"

  step "Generating server keys (via awg)"
  SERVER_PRIVKEY=$(gen_privkey)
  SERVER_PUBKEY=$(gen_pubkey "$SERVER_PRIVKEY")
  PSK=$(gen_psk)
  info "Server pubkey: ${SERVER_PUBKEY}"

  step "Generating Amnezia H values"
  gen_h_values
  info "H1=${H1}  H2=${H2}  H3=${H3}  H4=${H4}"

  step "Writing server config → ${CONFIG_DIR}/awg0.conf"
  sudo mkdir -p "$CONFIG_DIR"
  sudo tee "${CONFIG_DIR}/awg0.conf" > /dev/null << EOF
[Interface]
PrivateKey = ${SERVER_PRIVKEY}
Address = ${VPN_PREFIX}.0/24
ListenPort = ${SERVER_PORT}
Jc = ${JC}
Jmin = ${JMIN}
Jmax = ${JMAX}
S1 = ${S1}
S2 = ${S2}
S3 = ${S3}
S4 = ${S4}
H1 = ${H1}
H2 = ${H2}
H3 = ${H3}
H4 = ${H4}
EOF
  sudo chmod 600 "${CONFIG_DIR}/awg0.conf"
  echo "$SERVER_PUBKEY" | sudo tee "${CONFIG_DIR}/wireguard_server_public_key.key" > /dev/null
  echo "$SERVER_PRIVKEY" | sudo tee "${CONFIG_DIR}/wireguard_server_private_key.key" > /dev/null
  echo "$PSK"            | sudo tee "${CONFIG_DIR}/wireguard_psk.key"               > /dev/null
  sudo chmod 600 "${CONFIG_DIR}"/*.key

  step "Saving credentials → .env"
  env_set SERVER_PRIVKEY "$SERVER_PRIVKEY"
  env_set SERVER_PUBKEY  "$SERVER_PUBKEY"
  env_set PSK            "$PSK"
  env_set H1 "$H1"; env_set H2 "$H2"; env_set H3 "$H3"; env_set H4 "$H4"

  step "Creating Docker network (bridge: ${DOCKER_BRIDGE})"
  $DOCKER network create \
    --driver bridge \
    --opt com.docker.network.bridge.name="${DOCKER_BRIDGE}" \
    "${DOCKER_NET}" 2>/dev/null && info "Created" || info "Already exists"

  step "Starting container: ${CONTAINER_NAME}"
  $DOCKER rm -f "${CONTAINER_NAME}" 2>/dev/null || true
  _start_container
  info "Container running"

  step "Setting up host iptables FORWARD rules"
  _setup_iptables

  echo ""
  echo "✓ Setup complete."
}

# Start (or restart) the AmneziaWG container.
# amneziawg-go exits early on modern kernels detecting WireGuard support;
# WG_I_PREFER_BUGGY_USERSPACE_TO_POLISHED_KMOD=1 forces the userspace daemon.
# /dev/net/tun is required for the TUN interface it creates.
_start_container() {
  local cmd="WG_I_PREFER_BUGGY_USERSPACE_TO_POLISHED_KMOD=1 amneziawg-go awg0 \
    && sleep 0.5 \
    && grep -v '^Address = ' '${CONFIG_DIR}/awg0.conf' | awg setconf awg0 /dev/stdin \
    && ip addr add '${VPN_PREFIX}.0/24' dev awg0 \
    && ip link set awg0 up \
    && iptables -t nat -A POSTROUTING -s '${VPN_PREFIX}.0/24' -o eth0 -j MASQUERADE \
    && exec sleep infinity"

  $DOCKER run -d \
    --name "${CONTAINER_NAME}" \
    --network "${DOCKER_NET}" \
    --cap-add NET_ADMIN \
    --cap-add SYS_MODULE \
    --sysctl net.ipv4.ip_forward=1 \
    --sysctl net.ipv4.conf.all.src_valid_mark=1 \
    --device /dev/net/tun:/dev/net/tun \
    -v "${CONFIG_DIR}:${CONFIG_DIR}" \
    -p "${SERVER_PORT}:${SERVER_PORT}/udp" \
    --restart unless-stopped \
    "${IMAGE}" \
    sh -c "${cmd}"
}

_setup_iptables() {
  sudo iptables -C FORWARD -i "${DOCKER_BRIDGE}" -o "${HOST_IFACE}" -j ACCEPT 2>/dev/null \
    || sudo iptables -I FORWARD -i "${DOCKER_BRIDGE}" -o "${HOST_IFACE}" -j ACCEPT

  sudo iptables -C FORWARD -i "${HOST_IFACE}" -o "${DOCKER_BRIDGE}" \
    -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
    || sudo iptables -I FORWARD -i "${HOST_IFACE}" -o "${DOCKER_BRIDGE}" \
       -m state --state RELATED,ESTABLISHED -j ACCEPT

  command -v netfilter-persistent &>/dev/null \
    || sudo apt-get install -y -q iptables-persistent
  sudo netfilter-persistent save
  info "Rules persisted"
}

# ══════════════════════════════════════════════════════════════════
menu_add_client() {
  is_setup || die "Server not set up. Run setup first."

  read -rp "  Client name: " name
  [[ -n "$name" ]] || die "Name cannot be empty."
  list_clients | grep -qx "$name" && die "Client '${name}' already exists."

  step "Generating keys for '${name}'"
  CLIENT_PRIVKEY=$(gen_privkey)
  CLIENT_PUBKEY=$(gen_pubkey "$CLIENT_PRIVKEY")

  _JC=$(conf_get Jc);   _JMIN=$(conf_get Jmin); _JMAX=$(conf_get Jmax)
  _S1=$(conf_get S1);   _S2=$(conf_get S2);     _S3=$(conf_get S3); _S4=$(conf_get S4)
  _H1=$(conf_get H1);   _H2=$(conf_get H2);     _H3=$(conf_get H3); _H4=$(conf_get H4)
  _SERVER_PUBKEY=$(sudo cat "${CONFIG_DIR}/wireguard_server_public_key.key")
  _PSK=$(sudo cat "${CONFIG_DIR}/wireguard_psk.key")

  local n CLIENT_VPN_IP
  n=$(next_client_ip)
  CLIENT_VPN_IP="${VPN_PREFIX}.${n}"
  info "Assigned IP: ${CLIENT_VPN_IP}"

  step "Adding peer to server config"
  sudo tee -a "${CONFIG_DIR}/awg0.conf" > /dev/null << EOF

# Client: ${name}
[Peer]
PublicKey = ${CLIENT_PUBKEY}
PresharedKey = ${_PSK}
AllowedIPs = ${CLIENT_VPN_IP}/32
EOF

  step "Hot-adding peer to running interface"
  _wait_for_container
  $DOCKER exec "${CONTAINER_NAME}" sh -c "printf '%s' '${_PSK}' > /tmp/psk.key"
  $DOCKER exec "${CONTAINER_NAME}" awg set awg0 \
    peer "${CLIENT_PUBKEY}" \
    preshared-key /tmp/psk.key \
    allowed-ips "${CLIENT_VPN_IP}/32"
  $DOCKER exec "${CONTAINER_NAME}" rm /tmp/psk.key

  local outfile="${SCRIPT_DIR}/homelab_${name}_$(date +%Y_%m_%d).conf"
  step "Writing → $(basename "$outfile")"
  cat > "$outfile" << EOF
[Interface]
PrivateKey = ${CLIENT_PRIVKEY}
Address = ${CLIENT_VPN_IP}/32
DNS = ${DNS}
Jc = ${_JC}
Jmin = ${_JMIN}
Jmax = ${_JMAX}
S1 = ${_S1}
S2 = ${_S2}
S3 = ${_S3}
S4 = ${_S4}
H1 = ${_H1}
H2 = ${_H2}
H3 = ${_H3}
H4 = ${_H4}

[Peer]
PublicKey = ${_SERVER_PUBKEY}
PresharedKey = ${_PSK}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${ENDPOINT}:${SERVER_PORT}
PersistentKeepalive = 25
EOF
  chmod 600 "$outfile"

  echo ""
  echo "✓ Client '${name}' added — ${CLIENT_VPN_IP}"
  echo "  Config: ${outfile}"
  echo "  Import into Amnezia app. Delete file after importing."
}

_wait_for_container() {
  local attempts=0
  until is_running; do
    ((attempts++))
    [[ $attempts -ge 20 ]] && {
      echo ""
      echo "  Container not starting. Check logs:"
      echo "    $DOCKER logs ${CONTAINER_NAME}"
      die "Container failed to start."
    }
    echo -n "."
    sleep 2
  done
  echo ""
}

# ══════════════════════════════════════════════════════════════════
menu_remove_client() {
  is_setup || die "Server not set up."

  mapfile -t clients < <(list_clients)
  [[ ${#clients[@]} -gt 0 ]] || { echo "  No clients found."; return; }

  echo ""
  echo "  Clients:"
  for i in "${!clients[@]}"; do
    echo "    $((i+1))) ${clients[$i]}"
  done
  echo ""
  read -rp "  Choose client to remove [1-${#clients[@]}]: " choice
  [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le ${#clients[@]} ]] \
    || die "Invalid choice."

  local name="${clients[$((choice-1))]}"
  confirm "Remove client '${name}'?" || { echo "  Aborted."; return; }

  local pubkey
  pubkey=$(client_pubkey "$name")
  [[ -n "$pubkey" ]] || die "Could not find public key for '${name}'."

  step "Removing peer from running interface"
  $DOCKER exec "${CONTAINER_NAME}" awg set awg0 peer "${pubkey}" remove

  step "Removing peer from server config"
  remove_client_block "$name"

  echo ""
  echo "✓ Client '${name}' removed."
}

# ══════════════════════════════════════════════════════════════════
menu_status() {
  echo ""
  if is_setup; then
    info "Config:    ${CONFIG_DIR}/awg0.conf"
    if is_running; then
      info "Container: running"
      echo ""
      $DOCKER exec "${CONTAINER_NAME}" awg show awg0
    else
      info "Container: ✗ not running"
    fi
  else
    info "Server not set up."
  fi
}

# ══════════════════════════════════════════════════════════════════
menu_remove_setup() {
  echo ""
  echo "  This will:"
  echo "    • Stop and remove container '${CONTAINER_NAME}'"
  echo "    • Remove Docker network '${DOCKER_NET}'"
  echo "    • Remove config directory '${CONFIG_DIR}'"
  echo "    • Remove iptables FORWARD rules"
  echo "    • Clear credentials from .env"
  echo ""
  confirm "Proceed with full teardown?" || { echo "  Aborted."; return; }

  step "Stopping container"
  $DOCKER rm -f "${CONTAINER_NAME}" 2>/dev/null && info "Removed" || info "Not running"

  step "Removing Docker network"
  $DOCKER network rm "${DOCKER_NET}" 2>/dev/null && info "Removed" || info "Not found"

  step "Removing config directory"
  sudo rm -rf "${CONFIG_DIR}" && info "Removed ${CONFIG_DIR}"

  step "Removing iptables FORWARD rules"
  sudo iptables -D FORWARD -i "${DOCKER_BRIDGE}" -o "${HOST_IFACE}" -j ACCEPT 2>/dev/null || true
  sudo iptables -D FORWARD -i "${HOST_IFACE}" -o "${DOCKER_BRIDGE}" \
    -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
  sudo netfilter-persistent save 2>/dev/null || true
  info "Rules removed"

  step "Clearing credentials from .env"
  for key in SERVER_PRIVKEY SERVER_PUBKEY PSK H1 H2 H3 H4; do
    env_set "$key" ""
  done

  echo ""
  echo "✓ Teardown complete."
}

# ══════════════════════════════════════════════════════════════════
show_menu() {
  echo ""
  echo "  ┌─────────────────────────────┐"
  echo "  │     AmneziaWG Manager       │"
  echo "  ├─────────────────────────────┤"
  if is_running; then
    echo "  │  Server: ✓ running          │"
  elif is_setup; then
    echo "  │  Server: ⚠ config exists    │"
  else
    echo "  │  Server: ✗ not set up       │"
  fi
  echo "  ├─────────────────────────────┤"
  echo "  │  1) Setup server            │"
  echo "  │  2) Add client              │"
  echo "  │  3) Remove client           │"
  echo "  │  4) Status / peers          │"
  echo "  │  5) Remove setup            │"
  echo "  │  0) Exit                    │"
  echo "  └─────────────────────────────┘"
  echo ""
  read -rp "  Choice: " choice

  case "$choice" in
    1) menu_setup ;;
    2) menu_add_client ;;
    3) menu_remove_client ;;
    4) menu_status ;;
    5) menu_remove_setup ;;
    0) exit 0 ;;
    *) echo "  Invalid choice." ;;
  esac
}

# ── Entry point ───────────────────────────────────────────────────
case "${1:-}" in
  setup)          menu_setup ;;
  add-client)     menu_add_client ;;
  remove-client)  menu_remove_client ;;
  status)         menu_status ;;
  remove-setup)   menu_remove_setup ;;
  "")             while true; do show_menu; done ;;
  *)
    echo "Usage: $0 [setup|add-client|remove-client|status|remove-setup]"
    echo "       $0          — interactive menu"
    ;;
esac
