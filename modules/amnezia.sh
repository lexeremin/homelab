#!/bin/bash
# ── AmneziaWG server + client manager ────────────────────────────
# Sourced by homelab.sh — do not execute directly.
[[ -n "${SCRIPT_DIR:-}" ]] || { echo "Source via homelab.sh" >&2; exit 1; }

# ── Key generation helpers (via container, no wireguard-tools needed) ──
_awg_run()     { $DOCKER run --rm "${IMAGE}" awg "$@"; }
_gen_privkey() { _awg_run genkey; }
_gen_pubkey()  { echo "$1" | $DOCKER run --rm -i "${IMAGE}" awg pubkey; }
_gen_psk()     { _awg_run genpsk; }

# ── Config helpers ────────────────────────────────────────────────
_conf_get() { sudo grep "^${1} = " "${CONFIG_DIR}/awg0.conf" | head -1 | awk '{print $3}'; }

_next_client_ip() {
  local last=0 n
  while read -r n; do
    [[ "$n" -gt "$last" ]] && last="$n"
  done < <(sudo grep "^AllowedIPs = ${VPN_PREFIX}\." "${CONFIG_DIR}/awg0.conf" \
            | grep -oP "\.\K[0-9]+(?=/32)" || true)
  echo "$((last + 1))"
}

_list_clients() {
  sudo grep "^# Client: " "${CONFIG_DIR}/awg0.conf" | sed 's/^# Client: //' || true
}

_client_pubkey() {
  local name="$1"
  sudo awk "/^# Client: ${name}$/{found=1} found && /^PublicKey/{print \$3; exit}" \
    "${CONFIG_DIR}/awg0.conf"
}

_remove_client_block() {
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

_is_setup()   { sudo test -f "${CONFIG_DIR}/awg0.conf"; }
_is_running() {
  [[ "$($DOCKER inspect -f '{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null)" == "running" ]]
}

_wait_for_container() {
  local attempts=0
  until _is_running; do
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

# ── sysctl: ip_forward on host (--sysctl incompatible with --network host) ──
_ensure_sysctl() {
  sudo sysctl -w net.ipv4.ip_forward=1
  sudo sysctl -w net.ipv4.conf.all.src_valid_mark=1
  sudo tee /etc/sysctl.d/99-homelab-awg.conf > /dev/null << 'EOF'
net.ipv4.ip_forward = 1
net.ipv4.conf.all.src_valid_mark = 1
EOF
  info "sysctl rules persisted → /etc/sysctl.d/99-homelab-awg.conf"
}

# ── Container start (--network host: awg0 on host directly, no bridge NAT) ──
_start_container() {
  lsmod | grep -q amneziawg \
    || sudo modprobe amneziawg 2>/dev/null \
    || die "amneziawg kernel module not found. Build from: https://github.com/amnezia-vpn/amneziawg-linux-kernel-module"

  local cmd="ip link add dev awg0 type amneziawg \
    && grep -v '^Address = ' '${CONFIG_DIR}/awg0.conf' | awg setconf awg0 /dev/stdin \
    && ip addr add '${VPN_PREFIX}.1/24' dev awg0 \
    && ip link set awg0 up \
    && iptables -t nat -A POSTROUTING -s '${VPN_PREFIX}.0/24' -o ${HOST_IFACE} -j MASQUERADE \
    && exec sleep infinity"

  $DOCKER run -d \
    --name "${CONTAINER_NAME}" \
    --network host \
    --cap-add NET_ADMIN \
    --cap-add SYS_MODULE \
    -v "${CONFIG_DIR}:${CONFIG_DIR}" \
    --restart unless-stopped \
    "${IMAGE}" \
    sh -c "${cmd}"
}

# ══════════════════════════════════════════════════════════════════
amnezia_setup() {
  _is_setup && { echo "  Server already set up. Run 'remove-setup' first to reset."; return; }
  need docker "https://docs.docker.com/engine/install/"

  step "Pulling image: ${IMAGE}"
  $DOCKER pull "${IMAGE}"

  step "Generating server keys (via awg)"
  SERVER_PRIVKEY=$(_gen_privkey)
  SERVER_PUBKEY=$(_gen_pubkey "$SERVER_PRIVKEY")
  PSK=$(_gen_psk)
  info "Server pubkey: ${SERVER_PUBKEY}"

  step "Generating Amnezia H values"
  gen_h_values
  info "H1=${H1}  H2=${H2}  H3=${H3}  H4=${H4}"

  step "Writing server config → ${CONFIG_DIR}/awg0.conf"
  sudo mkdir -p "$CONFIG_DIR"
  sudo tee "${CONFIG_DIR}/awg0.conf" > /dev/null << EOF
[Interface]
PrivateKey = ${SERVER_PRIVKEY}
Address = ${VPN_PREFIX}.1/24
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

  step "Enabling ip_forward on host"
  _ensure_sysctl

  step "Starting container: ${CONTAINER_NAME}"
  $DOCKER rm -f "${CONTAINER_NAME}" 2>/dev/null || true
  _start_container
  info "Container running"

  echo ""
  echo "✓ Setup complete."
}

# ══════════════════════════════════════════════════════════════════
amnezia_add_client() {
  _is_setup || die "Server not set up. Run setup first."

  read -rp "  Client name: " name
  [[ -n "$name" ]] || die "Name cannot be empty."
  _list_clients | grep -qx "$name" && die "Client '${name}' already exists."

  step "Generating keys for '${name}'"
  CLIENT_PRIVKEY=$(_gen_privkey)
  CLIENT_PUBKEY=$(_gen_pubkey "$CLIENT_PRIVKEY")

  _JC=$(_conf_get Jc);   _JMIN=$(_conf_get Jmin); _JMAX=$(_conf_get Jmax)
  _S1=$(_conf_get S1);   _S2=$(_conf_get S2);     _S3=$(_conf_get S3); _S4=$(_conf_get S4)
  _H1=$(_conf_get H1);   _H2=$(_conf_get H2);     _H3=$(_conf_get H3); _H4=$(_conf_get H4)
  _SERVER_PUBKEY=$(sudo cat "${CONFIG_DIR}/wireguard_server_public_key.key")
  _PSK=$(sudo cat "${CONFIG_DIR}/wireguard_psk.key")

  local n CLIENT_VPN_IP
  n=$(_next_client_ip)
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

# ══════════════════════════════════════════════════════════════════
amnezia_remove_client() {
  _is_setup || die "Server not set up."

  mapfile -t clients < <(_list_clients)
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
  pubkey=$(_client_pubkey "$name")
  [[ -n "$pubkey" ]] || die "Could not find public key for '${name}'."

  step "Removing peer from running interface"
  $DOCKER exec "${CONTAINER_NAME}" awg set awg0 peer "${pubkey}" remove

  step "Removing peer from server config"
  _remove_client_block "$name"

  echo ""
  echo "✓ Client '${name}' removed."
}

# ══════════════════════════════════════════════════════════════════
amnezia_status() {
  echo ""
  if _is_setup; then
    info "Config:    ${CONFIG_DIR}/awg0.conf"
    if _is_running; then
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
amnezia_remove_setup() {
  echo ""
  echo "  This will:"
  echo "    • Stop and remove container '${CONTAINER_NAME}'"
  echo "    • Remove config directory '${CONFIG_DIR}'"
  echo "    • Remove iptables MASQUERADE rule"
  echo "    • Clear credentials from .env"
  echo ""
  confirm "Proceed with full teardown?" || { echo "  Aborted."; return; }

  step "Stopping container"
  $DOCKER rm -f "${CONTAINER_NAME}" 2>/dev/null && info "Removed" || info "Not running"

  step "Removing awg0 interface (if present)"
  sudo ip link del awg0 2>/dev/null && info "Removed awg0" || info "awg0 not found"

  step "Removing iptables MASQUERADE rule"
  sudo iptables -t nat -D POSTROUTING -s "${VPN_PREFIX}.0/24" -o "${HOST_IFACE}" -j MASQUERADE 2>/dev/null || true
  sudo netfilter-persistent save 2>/dev/null || true
  info "Rules removed"

  step "Removing config directory"
  sudo rm -rf "${CONFIG_DIR}" && info "Removed ${CONFIG_DIR}"

  step "Clearing credentials from .env"
  for key in SERVER_PRIVKEY SERVER_PUBKEY PSK H1 H2 H3 H4; do
    env_set "$key" ""
  done

  echo ""
  echo "✓ Teardown complete."
}

# ══════════════════════════════════════════════════════════════════
amnezia_menu() {
  echo ""
  echo "  ┌─────────────────────────────┐"
  echo "  │     AmneziaWG Manager       │"
  echo "  ├─────────────────────────────┤"
  if _is_running; then
    echo "  │  Server: ✓ running          │"
  elif _is_setup; then
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
  echo "  │  0) Back                    │"
  echo "  └─────────────────────────────┘"
  echo ""
  read -rp "  Choice: " choice

  case "$choice" in
    1) amnezia_setup ;;
    2) amnezia_add_client ;;
    3) amnezia_remove_client ;;
    4) amnezia_status ;;
    5) amnezia_remove_setup ;;
    0) return ;;
    *) echo "  Invalid choice." ;;
  esac
}

amnezia_dispatch() {
  case "${1:-}" in
    setup)          amnezia_setup ;;
    add-client)     amnezia_add_client ;;
    remove-client)  amnezia_remove_client ;;
    status)         amnezia_status ;;
    remove-setup)   amnezia_remove_setup ;;
    "")             while true; do amnezia_menu; done ;;
    *)
      echo "Usage: homelab.sh amnezia [setup|add-client|remove-client|status|remove-setup]"
      ;;
  esac
}
