#!/bin/bash
# ══════════════════════════════════════════════════════════════════
#  homelab.sh — Homelab manager (AmneziaWG + Headscale)
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

# ── Load libs ─────────────────────────────────────────────────────
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/docker.sh"

# ── Load modules ──────────────────────────────────────────────────
source "${SCRIPT_DIR}/modules/amnezia.sh"
source "${SCRIPT_DIR}/modules/headscale.sh"

# ══════════════════════════════════════════════════════════════════
homelab_menu() {
  echo ""
  echo "  ┌─────────────────────────────┐"
  echo "  │      Homelab Manager        │"
  echo "  ├─────────────────────────────┤"
  echo "  │  1) AmneziaWG               │"
  echo "  │  2) Headscale               │"
  echo "  │  0) Exit                    │"
  echo "  └─────────────────────────────┘"
  echo ""
  read -rp "  Choice: " choice

  case "$choice" in
    1) while true; do amnezia_menu || break; done ;;
    2) while true; do headscale_menu || break; done ;;
    0) exit 0 ;;
    *) echo "  Invalid choice." ;;
  esac
}

# ── Entry point ───────────────────────────────────────────────────
case "${1:-}" in
  amnezia)   shift; amnezia_dispatch "$@" ;;
  headscale) shift; headscale_dispatch "$@" ;;
  "")        while true; do homelab_menu; done ;;
  *)
    echo "Usage: $0 [amnezia|headscale] [subcommand]"
    echo ""
    echo "  amnezia   setup|add-client|remove-client|status|remove-setup"
    echo "  headscale setup|create-user|list-nodes|register-node|status|remove-setup"
    echo ""
    echo "  Omit subcommand for interactive menu."
    ;;
esac
