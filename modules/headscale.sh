#!/bin/bash
# ── Headscale control plane manager ──────────────────────────────
# Sourced by homelab.sh — do not execute directly.
[[ -n "${SCRIPT_DIR:-}" ]] || { echo "Source via homelab.sh" >&2; exit 1; }

_hs_is_setup()   { sudo test -f "${HEADSCALE_CONFIG_DIR}/config.yaml"; }
_hs_is_running() {
  [[ "$($DOCKER inspect -f '{{.State.Status}}' "${HEADSCALE_CONTAINER}" 2>/dev/null)" == "running" ]]
}

_hs_exec() { $DOCKER exec "${HEADSCALE_CONTAINER}" headscale "$@"; }

# ══════════════════════════════════════════════════════════════════
headscale_setup() {
  _hs_is_setup && { echo "  Headscale already set up. Run 'remove-setup' first to reset."; return; }
  need docker "https://docs.docker.com/engine/install/"

  step "Pulling image: ${HEADSCALE_IMAGE}"
  $DOCKER pull "${HEADSCALE_IMAGE}"

  step "Creating config directory: ${HEADSCALE_CONFIG_DIR}"
  sudo mkdir -p "${HEADSCALE_CONFIG_DIR}" "${HEADSCALE_DATA_DIR}"

  step "Writing config → ${HEADSCALE_CONFIG_DIR}/config.yaml"
  sudo tee "${HEADSCALE_CONFIG_DIR}/config.yaml" > /dev/null << EOF
---
server_url: ${SERVER_URL}
listen_addr: 0.0.0.0:${HEADSCALE_PORT}
grpc_listen_addr: 0.0.0.0:${HEADSCALE_GRPC_PORT}
grpc_allow_insecure: false

# Private key is auto-generated on first run
private_key_path: ${HEADSCALE_DATA_DIR}/private.key
noise:
  private_key_path: ${HEADSCALE_DATA_DIR}/noise_private.key

prefixes:
  v4: 100.64.0.0/10
  v6: fd7a:115c:a1e0::/48
  allocation: sequential

derp:
  urls:
    - https://controlplane.tailscale.com/derpmap/default
  auto_update_enabled: true
  update_frequency: 24h

disable_check_updates: false
ephemeral_node_inactivity_timeout: 30m

database:
  type: sqlite
  sqlite:
    path: ${HEADSCALE_DATA_DIR}/db.sqlite

log:
  level: info

acls_policy_path: ""

dns:
  magic_dns: true
  base_domain: homelab.internal

unix_socket: /var/run/headscale/headscale.sock
unix_socket_permission: "0770"
EOF
  sudo chmod 600 "${HEADSCALE_CONFIG_DIR}/config.yaml"

  step "Starting container: ${HEADSCALE_CONTAINER}"
  $DOCKER rm -f "${HEADSCALE_CONTAINER}" 2>/dev/null || true
  $DOCKER run -d \
    --name "${HEADSCALE_CONTAINER}" \
    --network host \
    --cap-add NET_ADMIN \
    -v "${HEADSCALE_CONFIG_DIR}:${HEADSCALE_CONFIG_DIR}" \
    -v "${HEADSCALE_DATA_DIR}:${HEADSCALE_DATA_DIR}" \
    --restart unless-stopped \
    "${HEADSCALE_IMAGE}" \
    headscale serve
  info "Container running"

  echo ""
  echo "✓ Headscale setup complete."
  echo "  Server URL: ${SERVER_URL}"
  echo "  Next steps:"
  echo "    ./homelab.sh headscale create-user <name>"
  echo "    ./homelab.sh headscale register-node"
}

# ══════════════════════════════════════════════════════════════════
headscale_create_user() {
  _hs_is_running || die "Headscale container not running. Run setup first."

  local username="${1:-}"
  if [[ -z "$username" ]]; then
    read -rp "  Username: " username
  fi
  [[ -n "$username" ]] || die "Username cannot be empty."

  step "Creating user '${username}'"
  _hs_exec users create "${username}"
  echo ""
  echo "✓ User '${username}' created."
}

# ══════════════════════════════════════════════════════════════════
headscale_list_nodes() {
  _hs_is_running || die "Headscale container not running."
  echo ""
  _hs_exec nodes list
}

# ══════════════════════════════════════════════════════════════════
headscale_register_node() {
  _hs_is_running || die "Headscale container not running."

  read -rp "  Username to register node to: " username
  [[ -n "$username" ]] || die "Username cannot be empty."

  read -rp "  Node key (from 'tailscale up --login-server ... --authkey ...' output): " nodekey
  [[ -n "$nodekey" ]] || die "Node key cannot be empty."

  step "Registering node"
  _hs_exec nodes register --user "${username}" --key "${nodekey}"
  echo ""
  echo "✓ Node registered."
}

# ══════════════════════════════════════════════════════════════════
headscale_status() {
  echo ""
  if _hs_is_setup; then
    info "Config:    ${HEADSCALE_CONFIG_DIR}/config.yaml"
    if _hs_is_running; then
      info "Container: running"
      echo ""
      _hs_exec nodes list 2>/dev/null || true
    else
      info "Container: ✗ not running"
    fi
  else
    info "Headscale not set up."
  fi
}

# ══════════════════════════════════════════════════════════════════
headscale_remove_setup() {
  echo ""
  echo "  This will:"
  echo "    • Stop and remove container '${HEADSCALE_CONTAINER}'"
  echo "    • Remove config directory '${HEADSCALE_CONFIG_DIR}'"
  echo "    • Remove data directory '${HEADSCALE_DATA_DIR}'"
  echo ""
  confirm "Proceed with full teardown?" || { echo "  Aborted."; return; }

  step "Stopping container"
  $DOCKER rm -f "${HEADSCALE_CONTAINER}" 2>/dev/null && info "Removed" || info "Not running"

  step "Removing config and data directories"
  sudo rm -rf "${HEADSCALE_CONFIG_DIR}" && info "Removed ${HEADSCALE_CONFIG_DIR}"
  sudo rm -rf "${HEADSCALE_DATA_DIR}"   && info "Removed ${HEADSCALE_DATA_DIR}"

  echo ""
  echo "✓ Headscale teardown complete."
}

# ══════════════════════════════════════════════════════════════════
headscale_menu() {
  echo ""
  echo "  ┌─────────────────────────────┐"
  echo "  │     Headscale Manager       │"
  echo "  ├─────────────────────────────┤"
  if _hs_is_running; then
    echo "  │  Server: ✓ running          │"
  elif _hs_is_setup; then
    echo "  │  Server: ⚠ config exists    │"
  else
    echo "  │  Server: ✗ not set up       │"
  fi
  echo "  ├─────────────────────────────┤"
  echo "  │  1) Setup server            │"
  echo "  │  2) Create user             │"
  echo "  │  3) List nodes              │"
  echo "  │  4) Register node           │"
  echo "  │  5) Status                  │"
  echo "  │  6) Remove setup            │"
  echo "  │  0) Back                    │"
  echo "  └─────────────────────────────┘"
  echo ""
  read -rp "  Choice: " choice

  case "$choice" in
    1) headscale_setup ;;
    2) headscale_create_user ;;
    3) headscale_list_nodes ;;
    4) headscale_register_node ;;
    5) headscale_status ;;
    6) headscale_remove_setup ;;
    0) return ;;
    *) echo "  Invalid choice." ;;
  esac
}

headscale_dispatch() {
  case "${1:-}" in
    setup)         headscale_setup ;;
    create-user)   shift; headscale_create_user "${1:-}" ;;
    list-nodes)    headscale_list_nodes ;;
    register-node) headscale_register_node ;;
    status)        headscale_status ;;
    remove-setup)  headscale_remove_setup ;;
    "")            while true; do headscale_menu; done ;;
    *)
      echo "Usage: homelab.sh headscale [setup|create-user|list-nodes|register-node|status|remove-setup]"
      ;;
  esac
}
